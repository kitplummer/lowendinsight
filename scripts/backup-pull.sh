#!/usr/bin/env bash
#
# Pull a backup out of Tigris onto this machine, decrypt it with the copy of
# the passphrase YOU keep, and prove it restores.
#
#   export BACKUP_PASSCODE='...'        # from your password manager
#   ./scripts/backup-pull.sh                       # newest
#   ./scripts/backup-pull.sh dumps/2026/09/25/033901Z.dump.gpg
#   ./scripts/backup-pull.sh --keep ~/backups      # keep the artifact
#   ./scripts/backup-pull.sh --list                # what is in the bucket
#
# Why this exists, given CI verifies every night:
#
#   1. Tigris is provisioned through Fly and lives in the same organisation as
#      the database. A copy here is outside that blast radius entirely, on
#      hardware you control. CI's artifact upload is the other off-Fly copy,
#      and it expires after 90 days.
#   2. CI decrypts with the CI secret, so it proves GitHub agrees with itself.
#      It cannot tell you that the copy in your password manager still opens
#      these files. Only this can, and a passphrase you cannot use is the same
#      as having no backup.
#
# Run it after every passphrase rotation, and otherwise often enough that the
# staleness line below stays uncomfortable to read. Each run records the date as
# the LEI_LAST_BACKUP_PULL repository variable, which the nightly job reads; a
# read-only bucket key is enough, because nothing here writes to the bucket.
#
# Requires: aws cli, gpg. Docker only for --restore.
set -uo pipefail

BUCKET="${BACKUP_BUCKET:-lei-pg-backups}"
ENDPOINT="${AWS_ENDPOINT_URL_S3:-https://fly.storage.tigris.dev}"
# Where the date of the last pull is recorded.
#
# A GitHub repository variable, not an object in the bucket. Writing a marker
# to the bucket forced this script -- which otherwise only reads -- to hold a
# key that can also delete backups, and a read-only key could never clear the
# nightly staleness warning. `gh` is already how an operator talks to this
# repository, and CI reads a variable for free.
PULL_VAR="LEI_LAST_BACKUP_PULL"
LATEST="meta/latest"
KEEP=""
WANT=""
MODE="pull"

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="${2:-}"; shift 2 ;;
    --list) MODE="list"; shift ;;
    --restore) MODE="restore"; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) WANT="$1"; shift ;;
  esac
done

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
dim()   { printf "\033[2m%s\033[0m\n" "$1"; }
fail()  { red "FAIL: $1"; exit 1; }

command -v aws >/dev/null || fail "aws cli is not installed."
command -v gpg >/dev/null || fail "gpg is not installed."

S3() { aws --endpoint-url "$ENDPOINT" "$@"; }

# Best effort, both ways: an operator without gh authenticated still gets a
# valid backup, they just do not update the date CI reads.
# `gh variable get` does not exist -- not in 2.46, which is what Ubuntu ships,
# and it is not what set/list are paired with. Reading it through `list --json`
# works on every version that can set it. The first version of this used `get`,
# so --list reported "never" however many times a pull had been recorded, while
# the write itself worked: a read path that silently disagreed with the write
# path beside it.
last_pull_date() {
  command -v gh >/dev/null || return 1

  local value
  value=$(gh variable list --json name,value \
    --jq ".[] | select(.name==\"${PULL_VAR}\") | .value" 2>/dev/null | tr -d '\r\n')

  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

record_pull() {
  command -v gh >/dev/null || return 1
  printf '%s' "$1" | gh variable set "$PULL_VAR" --body "$1" >/dev/null 2>&1
}

S3 s3 ls "s3://${BUCKET}/" >/dev/null 2>&1 \
  || fail "cannot read s3://${BUCKET}. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
       to a Tigris key for this bucket (flyctl storage dashboard)."

if [ "$MODE" = "list" ]; then
  bold "=== s3://${BUCKET}/dumps (times UTC) ==="

  # `s3 ls`, not `s3api list-objects-v2`.
  #
  # The Ubuntu package of aws-cli 2.31.35 rejects both list operations with
  # "badly formed help string" before it ever reaches the network -- with or
  # without --query, and `list-objects` v1 too. `head-object`, `get-object` and
  # `s3 ls` on the same build are fine, which is why a pull works and only this
  # listing broke. A broken argument model in one distro build of one operation.
  #
  # And there is no timezone conversion here, because there is nothing to
  # convert: the producer names every object with `date -u`, so the key *is* the
  # UTC timestamp. `s3 ls` prints the local zone in its own columns, which is
  # what made a 02:10Z object read as 22:10 the previous day; the key does not
  # have that problem. Sorting the keys is sorting by time.
  if ! listing=$(S3 s3 ls "s3://${BUCKET}/dumps/" --recursive 2>&1); then
    printf '%s\n' "$listing" | sed 's/^/    /' >&2
    fail "could not list s3://${BUCKET}/dumps (aws said the above)"
  fi

  if [ -z "$listing" ]; then
    dim "  no objects under dumps/ -- has the producer ever run?"
  else
    printf '%s\n' "$listing" \
      | sort -rk4 \
      | head -30 \
      | awk '{
          if ($4 ~ /^dumps\/[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9][0-9][0-9]Z/) {
            split($4, p, "/")
            printf "  %s-%s-%sT%s:%s:%sZ  %8.1f KiB  %s\n", \
              p[2], p[3], p[4], substr(p[5],1,2), substr(p[5],3,2), substr(p[5],5,2), $3/1024, $4
          } else {
            # A key the producer did not write. Shown rather than skipped, and
            # marked, because silently dropping objects from a backup listing is
            # how a listing stops being one.
            printf "  %-25s %8.1f KiB  %s  (key not dated by the producer)\n", \
              $1 " " $2, $3/1024, $4
          }
        }'
  fi

  echo
  dim "last local pull: $(last_pull_date || echo never)"
  exit 0
fi

[ -n "${BACKUP_PASSCODE:-}" ] || fail "BACKUP_PASSCODE is not set.
       export BACKUP_PASSCODE='<copy from your password manager>'
       Use the stored copy, not the CI secret -- decrypting with the CI secret
       only proves CI agrees with itself, which CI already does nightly."

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup() {
  # The decrypted dump holds org records, API key hashes and usage data.
  if [ -d "$WORKDIR" ]; then
    find "$WORKDIR" -type f -exec shred -u {} \; 2>/dev/null || true
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

bold "=== pulling a backup off Fly ==="

# --- which object -------------------------------------------------------
if [ -n "$WANT" ]; then
  KEY="$WANT"
else
  S3 s3 cp "s3://${BUCKET}/${LATEST}" "$WORKDIR/latest.txt" --only-show-errors \
    || fail "no meta/latest in the bucket. Has the producer run? flyctl logs -a lowendinsight-backup"
  KEY=$(tr -d '\r\n' < "$WORKDIR/latest.txt")
fi
[ -n "$KEY" ] || fail "no object to pull."

MODIFIED=$(S3 s3api head-object --bucket "$BUCKET" --key "$KEY" \
  --query LastModified --output text 2>/dev/null) \
  || fail "${KEY} is not in the bucket."

AGE_H=$(( ( $(date -u +%s) - $(date -u -d "$MODIFIED" +%s) ) / 3600 ))
echo "  object:   ${KEY}"
echo "  modified: ${MODIFIED} (${AGE_H}h ago)"

S3 s3 cp "s3://${BUCKET}/${KEY}" "$WORKDIR/lei.dump.gpg" --only-show-errors \
  || fail "download failed."
SIZE=$(stat -c%s "$WORKDIR/lei.dump.gpg")
echo "  size:     ${SIZE} bytes"
[ "$SIZE" -ge 10240 ] || fail "only ${SIZE} bytes -- that is an object, not a backup."

# --- decrypt with YOUR copy ---------------------------------------------
printf '%s' "$BACKUP_PASSCODE" > "$WORKDIR/pass"
if ! gpg --batch --yes --passphrase-file "$WORKDIR/pass" \
       --output "$WORKDIR/lei.dump" --decrypt "$WORKDIR/lei.dump.gpg" 2>"$WORKDIR/gpg.err"; then
  red "The passphrase in your password manager does NOT open this artifact."
  dim "$(tail -3 "$WORKDIR/gpg.err")"
  fail "Your stored copy has drifted from what the producer encrypts with.
       Nothing in CI can detect this, which is why this script exists.
       Fix it now: the artifacts are unreadable without a passphrase you have."
fi
green "  decrypted with your stored passphrase"

# --- readable, and optionally restorable --------------------------------
if command -v pg_restore >/dev/null; then
  pg_restore --list "$WORKDIR/lei.dump" > "$WORKDIR/toc.txt" \
    || fail "decrypted, but pg_restore cannot read it."
  echo "  tables with data: $(grep -c 'TABLE DATA' "$WORKDIR/toc.txt" || true)"
else
  head -c2 "$WORKDIR/lei.dump" | grep -q "PG" \
    || fail "decrypted, but this does not look like a pg_dump custom archive."
  dim "  pg_restore not installed; checked the archive header only"
fi

if [ "$MODE" = "restore" ]; then
  command -v docker >/dev/null || fail "--restore needs docker."
  bold "  restoring into a throwaway PostgreSQL 17"
  IMAGE=postgres:17-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652
  NAME="lei-restore-$$"
  docker run -d --name "$NAME" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=restored "$IMAGE" >/dev/null
  trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; cleanup' EXIT INT TERM
  for _ in $(seq 1 30); do docker exec "$NAME" pg_isready -q -U postgres && break; sleep 2; done
  docker cp "$WORKDIR/lei.dump" "$NAME:/tmp/lei.dump"
  docker exec "$NAME" pg_restore --no-owner --no-acl -U postgres -d restored /tmp/lei.dump 2>&1 \
    | grep -i error && fail "pg_restore reported errors."
  for t in orgs api_keys analysis_usage credit_entries schema_migrations; do
    printf '    %-20s %s\n' "$t" \
      "$(docker exec "$NAME" psql -U postgres -d restored -tAc "SELECT count(*) FROM public.${t}" 2>/dev/null || echo missing)"
  done
  green "  restored and queried"
fi

# --- keep it, if asked --------------------------------------------------
if [ -n "$KEEP" ]; then
  mkdir -p "$KEEP" || fail "cannot create ${KEEP}"
  chmod 700 "$KEEP"
  DEST="${KEEP%/}/$(basename "$KEY")"
  cp "$WORKDIR/lei.dump.gpg" "$DEST" || fail "could not write ${DEST}"
  chmod 600 "$DEST"
  green "  kept encrypted artifact at ${DEST}"
  dim "  it is still encrypted; keep the passphrase somewhere else"
fi

# --- record that this happened ------------------------------------------
#
# "Occasionally" is the kind of commitment that quietly becomes never. Writing
# the date back means the gap is a number someone can look at, rather than a
# memory. Best effort: a read-only key cannot write it, and a copy that was
# taken and not recorded is still a copy.
if record_pull "$(date -u +%Y-%m-%d)"; then
  green "  recorded this pull as ${PULL_VAR}"
else
  dim "  could not record the pull date -- install and authenticate gh to set"
  dim "  ${PULL_VAR}, which is what clears the nightly staleness warning."
  dim "  The copy itself is good either way."
fi

echo
green "This backup opens with the passphrase you keep, on a machine Fly does not control."
