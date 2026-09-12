<!--
Three sections are required. They exist because of specific failures in this
repo, not as ceremony -- each one is a question that, unasked, let a defect
through under a green build.

Delete the guidance comments; keep the headings.
-->

## What and why

<!-- What changes, and what problem it solves. Link the issue. -->

## Mechanism

<!--
For a fix: what actually causes the bug. Evidence, not inference.

Reasoning from source has been wrong here more than once -- LEI_GH_TOKEN was
named as a root cause twice before production logs showed it was Redix
defaulting to IPv4 on an IPv6-only network. A try/after was shipped for a
working-directory bug whose real mechanism was concurrency, so it fixed two
seeds out of five and CI failed again.

If you have not reproduced it, say so here and say what you did instead.

For a feature: what breaks if it is wrong, and what the failure looks like from
outside.
-->

## Negative control

<!--
The proof that the new test would catch the bug coming back.

Ideally a guard-verification mutation: add it to scripts/mutations.json and
paste the "N verified, 0 unguarded" line. Otherwise, revert the fix locally,
run the test, and paste the failure.

"Tests pass" is not a negative control. Every defect this repo has shipped
recently passed its tests -- they exercised the wrong layer.
-->

## Not verified

<!--
REQUIRED, and the most useful box on this form. What did you NOT check?

Untested paths, assumptions, things only CI can exercise, behaviour changes you
believe are safe but did not prove, anything that needs production state you do
not have.

"Nothing" is a valid answer only if it is true. An empty section reads as
completeness, and gaps reading as completeness is how most of this repo's
defects reached production.
-->

## Preflight

<!-- Paste the summary from scripts/preflight.sh, or say which stages you skipped and why. -->

```
```
