#!/usr/bin/env bash
#
# Every place that picks an Elixir/OTP version must agree with .tool-versions.
#
#   scripts/check-toolchain.sh
#
# CLAUDE.md said CI matched .tool-versions exactly, and it did -- while
# production built on elixir:1.15.7 with an alpine 3.18 runtime and the
# library's GitHub Action on 1.14.1. Tests ran on one toolchain and production
# on another, and a dependency (cowlib 2.20) that needs OTP 27 would have
# passed locally and failed only in the deploy build.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() { echo "  FAIL  $1"; fail=1; }

ERLANG=$(awk '$1=="erlang"{print $2}' .tool-versions)
ELIXIR_FULL=$(awk '$1=="elixir"{print $2}' .tool-versions)
ELIXIR=${ELIXIR_FULL%%-otp-*}
OTP_MAJOR=${ERLANG%%.*}

[ -n "$ERLANG" ] && [ -n "$ELIXIR" ] || { echo "FAIL: could not read erlang/elixir from .tool-versions"; exit 1; }
[ "$ELIXIR_FULL" = "$ELIXIR-otp-$OTP_MAJOR" ] || bad ".tool-versions: elixir $ELIXIR_FULL is not built for OTP $OTP_MAJOR"
echo "toolchain: Elixir $ELIXIR, OTP $ERLANG"

# GitHub Actions: every setup-beam pins both versions to .tool-versions.
checked=0
for f in .github/workflows/*.yml; do
  while IFS= read -r v; do
    checked=$((checked + 1))
    [ "$v" = "$ELIXIR" ] || bad "$f: elixir-version $v"
  done < <(sed -n 's/^ *elixir-version: *\([^ ]*\).*/\1/p' "$f")
  while IFS= read -r v; do
    [ "$v" = "$ERLANG" ] || bad "$f: otp-version $v"
  done < <(sed -n 's/^ *otp-version: *\([^ ]*\).*/\1/p' "$f")
  n_uses=$(grep -c "erlef/setup-beam" "$f")
  n_elixir=$(grep -c "elixir-version:" "$f")
  n_otp=$(grep -c "otp-version:" "$f")
  [ "$n_uses" -eq "$n_elixir" ] && [ "$n_uses" -eq "$n_otp" ] || bad "$f: $n_uses setup-beam steps but $n_elixir elixir-version / $n_otp otp-version pins"
  if grep -qE "image: *elixir:" "$f"; then bad "$f: container image elixir:* picks its own toolchain"; fi
done
[ "$checked" -gt 0 ] || bad "no elixir-version pins found in .github/workflows; checked nothing"

# Dockerfiles: builder images come from the pinned ARGs, never a bare elixir: tag.
dockerfiles=$(git ls-files | grep -E '(^|/)Dockerfile[^/]*$')
[ -n "$dockerfiles" ] || bad "no Dockerfiles found; checked nothing"
for f in $dockerfiles; do
  # The official elixir image pins Elixir and the OTP major only, so it is
  # accepted for the devcontainer and nothing that builds a release.
  while IFS= read -r tag; do
    [ "$tag" = "$ELIXIR-otp-$OTP_MAJOR" ] || bad "$f: FROM elixir:$tag, expected elixir:$ELIXIR-otp-$OTP_MAJOR"
    case "$f" in *.devcontainer/*) ;; *) bad "$f: builds on elixir:$tag; use the fully pinned hexpm/elixir image" ;; esac
  done < <(sed -n 's/^FROM \{1,\}elixir:\([^ ]*\).*/\1/p' "$f")
  grep -q "^FROM hexpm/elixir:" "$f" || continue
  [ "$(sed -n 's/^ARG ELIXIR_VERSION=//p' "$f")" = "$ELIXIR" ] || bad "$f: ELIXIR_VERSION is not $ELIXIR"
  [ "$(sed -n 's/^ARG ERLANG_VERSION=//p' "$f")" = "$ERLANG" ] || bad "$f: ERLANG_VERSION is not $ERLANG"
  grep -q '^FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION}' "$f" || bad "$f: hexpm/elixir image does not use the version ARGs"
  if grep -qE "^FROM alpine:" "$f"; then
    grep -q '^FROM alpine:${ALPINE_VERSION}' "$f" || bad "$f: runtime alpine differs from the builder's ALPINE_VERSION"
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "Toolchain pins agree: $checked workflow pins, $(echo "$dockerfiles" | wc -w | tr -d ' ') Dockerfiles."
