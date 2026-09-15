#!/usr/bin/env bash
# List an org's API keys, or revoke one, in production.
#
#   scripts/ops/api-keys.sh                 list lei-ops keys
#   scripts/ops/api-keys.sh revoke 85 115   revoke keys 85 and 115, then list
#   ORG=some-org scripts/ops/api-keys.sh    list another org's keys
#
# Prints key ids, names, scopes and active flags only -- never key values.
set -euo pipefail

APP="${APP:-lowendinsight}"
ORG="${ORG:-lei-ops}"

case "${1:-list}" in
  list) revoke="" ;;
  revoke | remove)
    shift
    [ $# -gt 0 ] || { echo "usage: $0 revoke <key id>..." >&2; exit 2; }
    revoke=""
    for id in "$@"; do
      [[ "$id" =~ ^[0-9]+$ ]] || { echo "key ids are numeric: $id" >&2; exit 2; }
      revoke+="IO.puts(\"revoke $id: \" <> inspect(elem(Lei.ApiKeys.revoke_key($id), 0)));"
    done
    ;;
  *) echo "usage: $0 [list | revoke <key id>...]" >&2; exit 2 ;;
esac

[[ "$ORG" =~ ^[a-z0-9-]+$ ]] || { echo "ORG must be a slug" >&2; exit 2; }

code="${revoke}
org = Lei.ApiKeys.get_org_by_slug(\"${ORG}\")
if org == nil, do: IO.puts(\"no org ${ORG}\"), else: (for k <- Lei.ApiKeys.list_keys(org), do: IO.puts(Enum.join([k.id, k.name, inspect(k.scopes), k.active], \" | \")))"

# Base64 so the Elixir survives ssh and shell quoting untouched.
b64=$(printf '%s' "$code" | base64 | tr -d '\n')
flyctl ssh console -a "$APP" -C "/opt/app/bin/lei_service rpc 'Code.eval_string(Base.decode64!(\"$b64\"))'"
