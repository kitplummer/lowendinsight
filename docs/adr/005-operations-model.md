# ADR-005: Agents operate production; the operator sets policy

**Status:** Proposed (2026-09-17)

## Context

LowEndInsight is run by one person. The go-live plan (#133, stage F #139) has
built what running payments needs: refunds and disputes reach the ledger
(#209), payment outcomes are counted (#213), every payment path has a kill
switch (#215), the ledger is reconciled with Stripe hourly (#216), and the
runbooks are skills that agents execute through `scripts/payments.sh` (#219).
An operations alert can reach the operator through ntfy (#220; delivery
confirmed 2026-09-17).

What is not decided is how these fit together: who notices, who acts, on what
authority, and when the operator is involved. As built today the answers are
poor:

- **The operator is in the loop for everything that moves money.** An agent
  may read and switch a path off; crediting a held payment, refunding, or
  switching back on waits for the operator. At 03:00 a held stablecoin
  payment that verifies cleanly on chain waits for someone asleep, although
  crediting it is simply the correct outcome. Where the agent has checked
  everything and the operator adds no information, an approval is a rubber
  stamp: it moves responsibility without adding judgement.
- **The boundary is enforced on the client.** `.claude/settings.json`
  permission rules match the command as typed. `./scripts/payments.sh refund`
  matches no rule, and in auto mode an unmatched command is judged by a
  classifier rather than prompting. And a cloud agent has no `flyctl` access,
  so it cannot act at all.
- **Nothing pages.** `monitor.yml` fails every 15 minutes into GitHub's
  failure email. It does not read any payment signal: reconciliation, held
  payments, switches left off, invalid webhooks, unmatched refunds.
- **There is no incident record.** What was noticed, what was done and why is
  spread across workflow logs, switch reasons and the conversation that
  happened to be open.
- **The watcher is unwatched.** GitHub's scheduled runs are best effort, and
  GitHub disables schedules in a public repository after 60 days without
  activity. A monitor that stopped would page nobody.

## Decision

### 1. Three roles

| role | is | does |
|---|---|---|
| **watcher** | GitHub Actions (`monitor.yml` and the scheduled workflows), external to the app | detects, de-duplicates, records, pages |
| **responder** | an agent running the runbook skills | diagnoses and acts **within policy**, and writes down what it did |
| **operator** | the person | sets policy; decides what policy says needs a person; reviews |

The watcher is outside the app because an app that is down cannot report
itself. The responder is an agent because the work is procedural and must not
wait for someone to wake. The operator's authority is exercised mainly through
policy, not through approving individual actions.

### 2. On the loop, not in it

A person is asked only when they have information or authority the agent
lacks -- the business, the law, the customer relationship -- or when an action
exceeds what policy allows. Otherwise, a verifiable, bounded, correct action is
taken by the agent and reported.

An approval that adds no information is not a safety control. The controls are
the limits, the verification every action already carries, the audit trail,
and the ability to undo.

### 3. Authority is set by reversibility and blast radius

| tier | examples | who |
|---|---|---|
| **read** | status, ledger, reconciliation, logs | agent |
| **stops harm, reversible** | switch a payment path off | agent, always; tells the operator |
| **correct, verifiable, bounded** | credit a held payment whose transfer verifies; refund within limits; switch a path back on that an agent switched off, once checks pass | agent, **within limits enforced by the app**; in the digest |
| **beyond limits, or judgement** | a refund over the limit or to an org with an open dispute; contesting a dispute; a ledger adjustment; anything with the Stripe account; key rotation | operator, paged; the agent prepares everything |
| **policy** | the tiers and the limits themselves | operator, as a reviewed change |

### 4. Policy is enforced in the app

Agents act through an **ops API** with a **scoped ops token**, not through
`flyctl ssh`:

- the app checks each operation against its tier and limits, so no spelling of
  a command, and no client configuration, gets past it
- every operation records who, why and what, as switches already do
- a cloud agent can use it, which `flyctl` access would not allow
- the token grants operations, never shell, database or secret access, and is
  revocable on its own

`scripts/payments.sh` becomes a client of the ops API. The Claude Code
permission rules stay, as defence in depth.

### 5. The flow

```
signals ──> watcher ──> incident issue ──> responder ──> ops API (limits, audit)
                │              ^                 │
                └── ntfy ──────┼── operator <────┘ only when policy says so
                               └── every step writes here
```

1. The **watcher** evaluates signals every run and records **state
   changes**: something breaks, something recovers.
2. A break opens (or updates) an **incident issue**, labelled `incident`, with
   the signal, the evidence, the runbook skill that applies, and a link to the
   run. Recovery comments and closes it. The issue is the one record the
   operator, agents and later sessions all read.
3. Opening an incident **fires the responder** (a routine triggered by the
   GitHub event). It loads the named runbook, acts within policy, and comments
   on the issue: what it saw, what it ran, the JSON results.
4. The operator is **paged** through `scripts/notify.sh` only as section 6
   says, and otherwise sees it in a **daily digest**.

### 6. What pages

Paged on the state change only -- once when it breaks, once when it recovers --
never on every run.

| priority | when |
|---|---|
| **5 urgent** | the site is down or degraded; a deploy rolled back; reconciliation `failed`, or a new discrepancy of a money-losing kind (`received_not_recorded`, `missing_in_stripe`, `amount_mismatch`, `not_succeeded`, `mode_mismatch`); `invalid` webhooks; the responder acted beyond or against policy, or could not verify an action |
| **4 high** | a decision is needed that policy reserves for the operator; held payments older than 24 hours; a path switched off for more than 4 hours; reconciliation not run for 2 hours; `unmatched` refund or dispute events |
| **3 default** | backups, the nightly CI or the strict audit failed |
| **not paged** | anything the responder resolved within policy: in the digest |

### 7. The watcher is watched

Every monitor run checks in with an external dead man's switch. If check-ins
stop, the switch pages the operator directly. The page that matters most is
the one saying the monitoring has stopped.

### 8. Autonomy widens by review

Limits start narrow (below). They widen through a change to the policy, made
after the digest shows the responder's decisions were ones the operator would
have made. An operator override -- undoing or reversing an agent action -- is
recorded, and is the evidence against widening.

## Starting limits

**For the operator to set.** These are proposals.

| operation | agent may, within | otherwise |
|---|---|---|
| `switch-off` any path | always | -- |
| `switch-on` | only a path an agent switched off; at least 30 minutes after; readiness `ok`; the last reconciliation not `failed` and with no new money-losing discrepancy | operator |
| `release` a held payment | when its transfer verifies; up to 10 a day | operator |
| `refund` | up to $29 each (the largest credit block); up to $100 a day in total; purchases under 30 days old; no open dispute on the org | operator |
| dispute evidence, ledger adjustments, key rotation, Stripe account | never | operator |

## Consequences

**Better**

- Nothing waits for someone asleep when policy already says what to do.
- The boundary is enforced where it cannot be bypassed, and it works for cloud
  agents.
- One record per incident, readable by the operator and by any later agent.
- Pages mean something, so they are not muted.
- The operator's attention goes to policy and to the decisions that are
  genuinely theirs.

**Costs and risks**

- An agent will, within limits, move real money on its own. The limits bound
  the damage; the audit trail and the digest are how a bad decision is found.
- More machinery: an ops API, a token, incident issues, a routine, a digest, a
  dead man's switch. Each is a place that can fail quietly, so each needs the
  same "what does it do when it cannot do its job" check as everything else
  here.
- A second dependency for response: the routine platform. Paging does not
  depend on it -- the watcher pages directly -- so an outage there delays
  response but does not hide the incident.
- Incident issues in a public repository are public. They carry signals,
  runbook names and actions, never customer data, keys or amounts tied to an
  identifiable customer.

## Rollout

Each stage is useful on its own, in this order:

1. **Page on what is already watched**, on state change (`monitor.yml`,
   `backup.yml`, `audit.yml`, the nightly CI, deploy rollbacks), through
   `scripts/notify.sh`.
2. **Watch the payment signals** in `monitor.yml`, with section 6's
   priorities, and open or close **incident issues**.
3. **The dead man's switch** on the monitor.
4. **The ops API**: scoped token, the section 3 tiers, the starting limits,
   the audit record. `scripts/payments.sh` moves onto it.
5. **The responder routine**, fired by incident issues, starting read-only
   and then within limits.
6. **The daily digest**, and the first review of the limits.

## Not decided here

- **The limit values**, until the operator sets them.
- **The dead man's switch service** (healthchecks.io or similar), and whether
  it pages through ntfy or on its own.
- **Whether routine runs push a notification** to the Claude app. Unverified;
  paging does not depend on it.
- **Self-hosting ntfy**, if the hosted service becomes a concern.
- **More than one operator.** Everything here assumes one.
