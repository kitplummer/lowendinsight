#!/usr/bin/env bash
#
# Create the backup producer: the Fly app, the Tigris bucket, the secrets and
# the scheduled Machine. Run once, by a human, from a machine logged in to Fly.
#
#   ./ops/backup/setup.sh
#
# Idempotent where Fly allows it: existing app, bucket and secrets are left
# alone, and it says so rather than failing. Re-running it after an incident is
# the intended way to rebuild the producer.
#
# It never takes a secret as an argument. Every value is read on stdin and
# passed to `flyctl secrets import`, so nothing reaches the process list, the
# shell history or a log.
set -uo pipefail

APP="lowendinsight-backup"
DB_APP="lowendinsight-db"
BUCKET="lei-db-backups"
REGION="iad"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "\033[32m  ok\033[0m   %s\n" "$1"; }
info() { printf "\033[2m  --\033[0m   %s\n" "$1"; }
die()  { printf "\033[31mFAILED\033[0m %s\n" "$1"; exit 1; }

command -v flyctl >/dev/null || die "flyctl is not installed."
flyctl auth whoami >/dev/null 2>&1 || die "flyctl is not logged in. Run: flyctl auth login"

bold "=== backup producer setup ==="

existing_secrets() {
  flyctl secrets list -a "$APP" --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print("\n".join(s["name"] for s in json.load(sys.stdin)))
except Exception:
    pass'
}

# --- the app -------------------------------------------------------------
if flyctl status -a "$APP" >/dev/null 2>&1; then
  info "app ${APP} already exists"
else
  flyctl apps create "$APP" --org personal || die "could not create ${APP}"
  ok "created app ${APP}"
fi

# --- the bucket ----------------------------------------------------------
#
# Tigris is provisioned as a Fly extension, so it lives in the same
# organisation as the database and shares its blast radius. That is deliberate
# and it is not the whole story: scripts/backup-pull.sh takes copies off Fly
# entirely, onto a machine a human controls. See ADR-006.
if flyctl storage list 2>/dev/null | grep -q "$BUCKET"; then
  info "bucket ${BUCKET} already exists"
elif [ -n "$(existing_secrets | grep -x BUCKET_NAME || true)" ]; then
  # Secrets present, bucket absent. This is what a destroy-and-recreate leaves
  # behind: the app still holds keys for a bucket that no longer exists, and
  # every check that asks only whether a secret is set would pass while the
  # producer uploads nowhere.
  #
  # Tigris also holds a deleted bucket name for a while, so recreating under the
  # same name fails with "recently deleted and unavailable" -- which is why this
  # says to pick a new one rather than retrying.
  die "${APP} has bucket credentials staged, but no bucket named ${BUCKET} exists.
       Something destroyed it, or it was created under a different name.

       Create it, attached to this app so the keys are replaced:
         flyctl storage create -n ${BUCKET} -o personal -a ${APP}

       Without -a the app keeps the old, dead keys and the producer will upload
       nowhere while reporting success. If Tigris refuses the name as recently
       deleted, choose another and update BUCKET in this script,
       .github/workflows/backup.yml and scripts/backup-pull.sh."
else
  bold "Creating bucket ${BUCKET}."
  echo "flyctl prints the access keys once. Put them in your password manager"
  echo "before continuing -- they cannot be read back."
  flyctl storage create -n "$BUCKET" -o personal -a "$APP" || die "could not create bucket"
  ok "created bucket ${BUCKET}"
fi

# --- secrets -------------------------------------------------------------
#
# `flyctl storage create` sets the bucket's own credentials on this app --
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL_S3, AWS_REGION and
# BUCKET_NAME. Do not paste those; asking for them once produced a prompt that
# looked like it wanted the keys flyctl had just printed, which is how a live
# credential ends up somewhere it should not be.
#
# Only two values come from a human, and only PG_DUMP_URL is specific to this
# app: it points at the database's private address, because there is no proxy
# and no tunnel any more.
#
# Parsed as JSON deliberately. The table output prefixes a staged secret with
# "* ", so reading the first field returns an asterisk rather than a name, and
# every secret reads as missing.


EXISTING=$(existing_secrets)
missing=""
for want in PG_DUMP_URL BACKUP_PASSPHRASE; do
  echo "$EXISTING" | grep -qx "$want" || missing="$missing $want"
done

# The bucket's keys should already be here. If they are not, the storage
# extension did not attach to this app and the producer cannot upload.
for want in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY BUCKET_NAME; do
  echo "$EXISTING" | grep -qx "$want" \
    || die "${want} is not set on ${APP}. flyctl storage create should have set it.
       Check: flyctl storage list  and  flyctl secrets list -a ${APP}"
done
ok "bucket credentials present (set by flyctl storage create)"

if [ -z "$missing" ]; then
  info "PG_DUMP_URL and BACKUP_PASSPHRASE already set"
else
  bold "Two secrets are needed:${missing}"
  cat <<PROMPT

Paste one line per secret, exactly as shown, then press Ctrl-D.
Nothing is echoed to a log, and neither value is a Tigris key.

  PG_DUMP_URL=postgres://lei_backup:PASS@${DB_APP}.internal:5432/lei_service_prod
  BACKUP_PASSPHRASE=<the same passphrase the existing artifacts use>

To stop and come back to this, press Ctrl-C: the app and the bucket already
exist and re-running this script picks up from here.

PROMPT
  flyctl secrets import -a "$APP" || die "could not import secrets"
  ok "secrets imported"
fi

# --- image ---------------------------------------------------------------
bold "Building the image"
cd "$(dirname "$0")" || die "cannot enter ops/backup"
flyctl deploy --build-only --push -a "$APP" --config fly.toml \
  || die "image build failed"

IMAGE=$(flyctl image show -a "$APP" --json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Ref") or d.get("ref") or "")' 2>/dev/null)
[ -n "$IMAGE" ] || IMAGE="registry.fly.io/${APP}:latest"
ok "image ${IMAGE}"

# --- the scheduled machine ----------------------------------------------
#
# 'daily' is Fly's own scheduler. The exact minute is Fly's to choose, which is
# fine: CI checks that an object arrived in the last 26 hours, not that it
# arrived at a particular time.
#
# --restart no: a failed backup must stay failed and be noticed, not be retried
# into a success that hides why the first attempt did not work.
if flyctl machine list -a "$APP" --json 2>/dev/null | grep -q '"schedule": *"daily"'; then
  info "a daily scheduled machine already exists"
  echo "     to replace it: flyctl machine destroy --force <id> -a ${APP}"
else
  flyctl machine run "$IMAGE" --schedule daily --restart no -a "$APP" \
    --vm-memory 512 --region "$REGION" || die "could not create the scheduled machine"
  ok "scheduled machine created (daily)"
fi

bold "=== done ==="
cat <<'NEXT'

Next, and none of it is optional:

  1. Run it once now, and watch it:
       flyctl machine list -a lowendinsight-backup
       flyctl machine start <id> -a lowendinsight-backup
       flyctl logs -a lowendinsight-backup

  2. Give CI read-only access to the bucket. Create a second Tigris key with
     read scope in the Tigris dashboard (flyctl storage dashboard), then:
       gh secret set TIGRIS_READ_ACCESS_KEY_ID
       gh secret set TIGRIS_READ_SECRET_ACCESS_KEY

  3. Take a copy off Fly, and keep doing it:
       export BACKUP_PASSCODE='<from your password manager>'
       ./scripts/backup-pull.sh

NEXT
