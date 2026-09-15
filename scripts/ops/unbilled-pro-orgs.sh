#!/usr/bin/env bash
# Read-only: list production orgs that are Pro without a Stripe subscription.
#
#   scripts/ops/unbilled-pro-orgs.sh
#
# Pro is unlimited at the gate and billed only through a subscription, so a Pro
# org with no subscription id was never charged after creation. Two paths made
# them before the 2026-09-14 security fixes: ACP's lei-pro-monthly SKU (a
# one-off charge), and /signup/success activating a Pro org without payment.
#
# Also lists every completed ACP session, whatever org it created.
# Prints ids, slugs, statuses, dates and counts -- no keys, no customer ids.
set -euo pipefail

APP="${APP:-lowendinsight}"

code='
import Ecto.Query
alias Lei.{Repo, Org, ApiKey, AcpCheckoutSession}

keys = fn id -> Repo.aggregate(from(k in ApiKey, where: k.org_id == ^id and k.active), :count) end

IO.puts("== Pro orgs without a Stripe subscription ==")
pro = Repo.all(from(o in Org, where: o.tier == "pro" and is_nil(o.stripe_subscription_id), order_by: o.inserted_at))
if pro == [], do: IO.puts("(none)")
for o <- pro do
  u = Lei.UsageTracker.get_current_usage(o.id)
  IO.puts(Enum.join([
    "org #{o.id}", o.slug, "status=#{o.status}",
    "customer=#{if o.stripe_customer_id, do: "yes", else: "no"}",
    "created=#{o.inserted_at}", "active_keys=#{keys.(o.id)}",
    "this_month=#{u.cache_hits}h/#{u.cache_misses}m"
  ], " | "))
end

IO.puts("")
IO.puts("== Completed ACP sessions ==")
sessions = Repo.all(from(s in AcpCheckoutSession, where: s.status == "completed", order_by: s.inserted_at))
if sessions == [], do: IO.puts("(none)")
for s <- sessions do
  org = s.org_id && Repo.get(Org, s.org_id)
  IO.puts(Enum.join([
    s.sku, "cents=#{s.amount_cents}", "paid=#{if s.stripe_payment_intent_id, do: "yes", else: "no"}",
    "created=#{s.inserted_at}",
    (if org, do: "org #{org.id} #{org.slug} tier=#{org.tier} status=#{org.status}", else: "no org")
  ], " | "))
end
'

# Base64 so the Elixir survives ssh and shell quoting untouched.
b64=$(printf '%s' "$code" | base64 | tr -d '\n')
flyctl ssh console -a "$APP" -C "/opt/app/bin/lowendinsight_get rpc 'Code.eval_string(Base.decode64!(\"$b64\"))'"
