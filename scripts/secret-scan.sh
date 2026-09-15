#!/usr/bin/env bash
#
# Reads a page or report body on stdin and reports secret-shaped content.
#
#   curl -s https://lowendinsight.dev/ | scripts/secret-scan.sh "home page"
#
# Exit 0: scanned, nothing found.
# Exit 1: something secret-shaped was found. The pattern names are printed;
#         the matched text never is -- this runs in CI logs.
# Exit 2: nothing to scan. An empty body is a fetch that failed, not a clean
#         page, and a scan of nothing must not read as a pass.
#
# Analysis reports embedded the whole application environment, including the
# Stripe secret key, the webhook signing secret and two signing secrets, and
# served them on public pages for months while every check was green
# (security, 2026-09-14). This looks for that class of content on what the
# deployment actually serves.

set -uo pipefail

LABEL="${1:-input}"
BODY=$(cat)

if [ -z "${BODY//[[:space:]]/}" ]; then
  echo "secret-scan: ${LABEL}: empty input, nothing scanned" >&2
  exit 2
fi

# name|extended regex. POSIX ERE only -- no \b, which BusyBox and BSD grep
# do not all support; word boundaries are spelled out as character classes.
# Values are secret-shaped, key names are the settings
# whose appearance in a public body means configuration is being published.
PATTERNS=(
  'stripe secret key|(^|[^0-9A-Za-z_])[sr]k_(live|test)_[0-9A-Za-z]{16,}'
  'stripe webhook secret|(^|[^0-9A-Za-z_])whsec_[0-9A-Za-z]{16,}'
  'lei api key|(^|[^0-9A-Za-z_])lei_[0-9a-f]{32}($|[^0-9A-Za-z_])'
  'lei recovery code|(^|[^0-9A-Za-z_])lei_recover_[0-9a-f]{24}($|[^0-9A-Za-z_])'
  'github token|(^|[^0-9A-Za-z_])(ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{30,}|(^|[^0-9A-Za-z_])github_pat_[0-9A-Za-z_]{40,}'
  'fly token|FlyV1 fm[0-9A-Za-z_+/=,-]{20,}|(^|[^0-9A-Za-z_])fo1_[0-9A-Za-z_-]{20,}'
  'aws access key|(^|[^0-9A-Za-z_])AKIA[0-9A-Z]{16}($|[^0-9A-Za-z_])'
  'private key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'jwt|(^|[^0-9A-Za-z_])eyJ[0-9A-Za-z_-]{10,}\.eyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}'
  'database url with password|postgres(ql)?://[^:/[:space:]"]+:[^@[:space:]"]+@'
  'redis url with password|rediss?://[^:/[:space:]"]*:[^@[:space:]"]+@'
  'secret setting name|["'"'"':]?(stripe_secret_key|stripe_webhook_secret|session_secret_key_base|secret_key_base|jwt_secret|hex_api_key|database_url|redis_url)["'"'"']?[[:space:]]*(:|=>|=)'
)

FOUND=()
for entry in "${PATTERNS[@]}"; do
  name="${entry%%|*}"
  regex="${entry#*|}"
  if printf '%s' "$BODY" | grep -qE -- "$regex"; then
    FOUND+=("$name")
  fi
done

if [ "${#FOUND[@]}" -gt 0 ]; then
  printf 'secret-scan: %s: found %s\n' "$LABEL" "$(IFS=,; echo "${FOUND[*]}" | sed 's/,/, /g')"
  exit 1
fi

exit 0
