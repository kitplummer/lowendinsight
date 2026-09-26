#!/usr/bin/env bash
#
# Take one logical backup of the production database and put it in Tigris.
#
# Runs as a scheduled Fly Machine in the same organisation and private network
# as the database, so it reaches Postgres directly at
# lowendinsight-db.internal:5432. That is the point of it running here: the
# previous version of this ran on a GitHub runner behind `flyctl proxy`, and
# the proxy, the flyctl binary, the pgdg apt repository and a WireGuard tunnel
# were all in the nightly path. See docs/adr/006-backup-near-the-data.md.
#
# Required environment (set with: flyctl secrets import -a lowendinsight-backup)
#   PG_DUMP_URL          postgres://user:pass@lowendinsight-db.internal:5432/lowendinsight_get_prod
#   BACKUP_PASSPHRASE    symmetric key for the artifact
#   AWS_ACCESS_KEY_ID    Tigris key, write scope
#   AWS_SECRET_ACCESS_KEY
#   AWS_ENDPOINT_URL_S3  https://fly.storage.tigris.dev
#   BUCKET_NAME          bucket name
#
# All five of those are set by `flyctl storage create -a lowendinsight-backup`;
# only PG_DUMP_URL and BACKUP_PASSPHRASE are set by hand.
# Optional
#   NTFY_TOKEN, NTFY_TOPIC   page immediately on failure; CI's freshness check
#                            is the authoritative detector, this is only faster
#
# Every check here fails the run rather than reporting a backup that is not
# one. An empty dump, an unreadable dump, an artifact that does not decrypt, or
# an object that is not in the bucket afterwards are all failures.

set -uo pipefail

STAMP="$(date -u +%Y/%m/%d/%H%M%SZ)"
KEY="dumps/${STAMP}.dump.gpg"
WORK="$(mktemp -d)"
chmod 700 "$WORK"

# The plaintext dump holds org records, API key hashes and usage data. It never
# outlives this process, on any exit path.
cleanup() {
  find "$WORK" -type f -exec shred -u {} \; 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

page() {
  [ -n "${NTFY_TOKEN:-}" ] && [ -n "${NTFY_TOPIC:-}" ] || return 0
  # Token over stdin, never on a command line -- same handling as
  # scripts/notify.sh.
  printf 'Authorization: Bearer %s\nTitle: LEI: backup producer failed\nPriority: 4\nTags: floppy_disk\n' \
    "$NTFY_TOKEN" \
    | curl -s -o /dev/null --max-time 20 -H @- --data-binary "$1" \
      "${NTFY_SERVER:-https://ntfy.sh}/${NTFY_TOPIC}" || true
}

die() {
  log "FAILED: $1"
  page "$1"
  exit 1
}

# BACKUP_BUCKET is accepted as an override so this image can be pointed at a
# different bucket by hand, but BUCKET_NAME -- what the storage extension sets
# -- is the normal source.
BACKUP_BUCKET="${BACKUP_BUCKET:-${BUCKET_NAME:-}}"

for var in PG_DUMP_URL BACKUP_PASSPHRASE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
           AWS_ENDPOINT_URL_S3 BACKUP_BUCKET; do
  [ -n "${!var:-}" ] || die "${var} is not set, so no backup was taken."
done

S3() { aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3 "$@"; }
S3API() { aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api "$@"; }

# --- dump ---------------------------------------------------------------
log "dumping to ${KEY}"
pg_dump --format=custom --no-owner --no-acl --file="$WORK/lei.dump" "$PG_DUMP_URL" \
  || die "pg_dump did not complete."

SIZE=$(stat -c%s "$WORK/lei.dump")
log "dump size: ${SIZE} bytes"

# A tiny dump means it ran against an empty or wrong database. Silent success
# is the failure mode that matters for a backup.
[ "$SIZE" -ge 10240 ] || die "Dump is only ${SIZE} bytes -- suspiciously small. Not uploading."

# --- readable, not merely present ---------------------------------------
pg_restore --list "$WORK/lei.dump" > "$WORK/toc.txt" \
  || die "pg_restore could not read the dump it just produced."

for t in orgs api_keys analysis_usage credit_entries schema_migrations; do
  grep -q "TABLE DATA public $t" "$WORK/toc.txt" \
    || die "Expected table '${t}' is missing from the dump."
done
log "tables with data: $(grep -c 'TABLE DATA' "$WORK/toc.txt")"

# --- encrypt, and prove it decrypts -------------------------------------
printf '%s' "$BACKUP_PASSPHRASE" > "$WORK/pass"
gpg --batch --yes --symmetric --cipher-algo AES256 \
  --passphrase-file "$WORK/pass" \
  --output "$WORK/lei.dump.gpg" "$WORK/lei.dump" || die "gpg could not encrypt the dump."

# Encrypting an archive nobody has decrypted is how a backup becomes a
# file-shaped object. Round-trip before uploading.
gpg --batch --yes --passphrase-file "$WORK/pass" \
  --output "$WORK/roundtrip.dump" --decrypt "$WORK/lei.dump.gpg" \
  || die "The artifact does not decrypt with the passphrase that encrypted it."

cmp -s "$WORK/lei.dump" "$WORK/roundtrip.dump" \
  || die "Decrypted artifact does not match the dump."

# --- upload, and confirm it landed --------------------------------------
S3 cp "$WORK/lei.dump.gpg" "s3://${BACKUP_BUCKET}/${KEY}" --only-show-errors \
  || die "Upload to ${BACKUP_BUCKET} failed."

# `aws s3 cp` exiting zero is not the object being there. Ask the bucket.
REMOTE=$(S3API head-object --bucket "$BACKUP_BUCKET" --key "$KEY" \
  --query ContentLength --output text 2>/dev/null) \
  || die "Uploaded ${KEY} but the bucket does not have it."

LOCAL=$(stat -c%s "$WORK/lei.dump.gpg")
[ "$REMOTE" = "$LOCAL" ] \
  || die "${KEY} is ${REMOTE} bytes in the bucket and ${LOCAL} locally."

# A pointer to the newest object, so a reader never has to sort a listing and
# never sees a half-written key. Written last, on purpose: it is only true
# once the object above is confirmed present.
printf '%s\n' "$KEY" > "$WORK/latest"
S3 cp "$WORK/latest" "s3://${BACKUP_BUCKET}/meta/latest" --only-show-errors \
  || die "Uploaded the dump but could not update meta/latest, so nothing will find it."

log "ok: ${KEY} (${LOCAL} bytes)"
