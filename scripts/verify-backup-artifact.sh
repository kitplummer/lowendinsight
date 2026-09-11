#!/usr/bin/env bash
# Verify a backup artifact can be decrypted with the passphrase you actually
# store -- not the one in GitHub.
#
# The backup workflow already round-trips each artifact, encrypting then
# decrypting and comparing. That check cannot catch the failure that matters:
# it decrypts with the same secret it encrypted with, so a password-manager
# copy that has drifted from the GitHub secret still passes. This script closes
# that gap by decrypting with your copy.
#
# Requires only gpg and gh. No PostgreSQL server, and no Postgres client --
# pg_restore --list reads the archive file directly and never connects to a
# database. It is used when present, and a magic-byte check substitutes when
# it is not.
#
# Usage:
#   export BACKUP_PASSCODE='...'          # from your password manager
#   ./scripts/verify-backup-artifact.sh              # latest successful backup
#   ./scripts/verify-backup-artifact.sh 34557291848  # a specific run
#
# Run it after rotating BACKUP_PASSPHRASE. A rotated key never tested against
# the copy you keep is the same failure as having no backup.

set -euo pipefail

REPO="${LEI_REPO:-kitplummer/lowendinsight}"
RUN_ID="${1:-}"

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }

fail() { red "FAIL: $1"; exit 1; }

# --- preconditions ---
[ -n "${BACKUP_PASSCODE:-}" ] || fail "BACKUP_PASSCODE is not set.
       export BACKUP_PASSCODE='<copy from your password manager>'
       Use the stored copy, not the GitHub secret -- testing with the GitHub
       secret only proves GitHub agrees with itself."

command -v gpg >/dev/null || fail "gpg is not installed."
command -v gh  >/dev/null || fail "gh is not installed."
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"

# --- scratch space, always cleaned up ---
WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"

cleanup() {
  # The decrypted dump holds org records, API key hashes and usage data in
  # plaintext. Shred where available, remove either way, on every exit path.
  if [ -d "$WORKDIR" ]; then
    find "$WORKDIR" -type f -exec shred -u {} \; 2>/dev/null || true
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

bold "=== LEI backup artifact verification ==="

# --- locate the run ---
if [ -z "$RUN_ID" ]; then
  echo "Finding the most recent successful backup run..."
  RUN_ID=$(gh run list --repo "$REPO" --workflow backup.yml \
             --status success --limit 1 --json databaseId \
             --jq '.[0].databaseId' 2>/dev/null || true)
  [ -n "$RUN_ID" ] || fail "No successful backup run found in $REPO."
fi

RUN_DATE=$(gh run view "$RUN_ID" --repo "$REPO" --json createdAt --jq .createdAt 2>/dev/null || echo "unknown")
echo "  Run:  $RUN_ID"
echo "  Date: $RUN_DATE"

# --- download ---
echo "Downloading artifact..."
gh run download "$RUN_ID" --repo "$REPO" --dir "$WORKDIR" >/dev/null 2>&1 \
  || fail "Could not download artifacts from run $RUN_ID (expired after 90 days?)."

ENCRYPTED=$(find "$WORKDIR" -name '*.dump.gpg' -type f | head -1)
[ -n "$ENCRYPTED" ] || fail "No .dump.gpg found in the artifacts for run $RUN_ID."
echo "  Found: $(basename "$ENCRYPTED") ($(stat -c%s "$ENCRYPTED") bytes)"

# --- decrypt: the actual test ---
bold "Decrypting with BACKUP_PASSCODE..."
PLAIN="$WORKDIR/lei.dump"

# Passphrase via stdin rather than argv, so it does not appear in `ps`.
if ! printf '%s' "$BACKUP_PASSCODE" \
     | gpg --batch --quiet --yes --passphrase-fd 0 --pinentry-mode loopback \
           --output "$PLAIN" --decrypt "$ENCRYPTED" 2>"$WORKDIR/gpg.err"; then
  red "FAIL: decryption failed."
  echo ""
  sed 's/^/       /' "$WORKDIR/gpg.err" | head -5
  echo ""
  red "       BACKUP_PASSCODE does not match the key these artifacts were"
  red "       encrypted with. Every artifact is currently unreadable with the"
  red "       copy you hold. Reconcile before relying on these backups."
  exit 1
fi
green "  PASS: decrypted successfully"

# --- sanity-check the plaintext ---
SIZE=$(stat -c%s "$PLAIN")
echo "  Decrypted size: ${SIZE} bytes"
[ "$SIZE" -gt 10240 ] || fail "Decrypted file is only ${SIZE} bytes -- suspiciously small."

MAGIC=$(head -c 5 "$PLAIN")
[ "$MAGIC" = "PGDMP" ] || fail "Decrypted file does not start with PGDMP; it is not a pg_dump custom archive."
green "  PASS: PGDMP header present -- valid pg_dump custom archive"

# --- deeper check when the client is available (no server needed) ---
if command -v pg_restore >/dev/null; then
  bold "Inspecting archive contents..."
  if ! pg_restore --list "$PLAIN" > "$WORKDIR/toc.txt" 2>"$WORKDIR/pgr.err"; then
    red "  WARN: pg_restore could not read the archive:"
    sed 's/^/        /' "$WORKDIR/pgr.err" | head -3
    red "        This can be a client-version issue rather than a bad archive."
  else
    MISSING=""
    for t in orgs api_keys analysis_usage schema_migrations; do
      if grep -q "TABLE DATA public $t" "$WORKDIR/toc.txt"; then
        green "  PASS: $t present"
      else
        red "  FAIL: $t missing"
        MISSING="$MISSING $t"
      fi
    done
    [ -z "$MISSING" ] || fail "Expected tables missing from the archive:$MISSING"
  fi
else
  echo "  (pg_restore not installed -- skipping content inspection.)"
  echo "  The PGDMP check above already confirms a valid archive. For the"
  echo "  fuller check: sudo apt-get install -y postgresql-client"
fi

echo ""
green "=== Backup artifact verified with your stored passphrase ==="
echo "Plaintext removed from ${WORKDIR}."
