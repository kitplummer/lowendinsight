# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Build context: repo root (../../)
# Usage: docker build -f apps/lei_service/Dockerfile .

# Builder and runtime share one Alpine release so the release's ERTS links
# against the same musl and OpenSSL it runs with. Versions must match
# .tool-versions; scripts/check-toolchain.sh enforces it.
ARG ELIXIR_VERSION=1.20.4
ARG ERLANG_VERSION=28.5.0.6
ARG ALPINE_VERSION=3.24.1

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION} AS builder

ARG MIX_ENV=prod

WORKDIR /opt/app

# The base image is pinned, so its packages are not upgraded past it.
#
# `apk update && apk upgrade` ran here and defeated that pinning: every package
# in a 3.24.1 image was upgraded against whatever the live mirrors held at build
# time, so the same tag did not produce the same image. For a Zarf bundle meant
# for airgapped distribution, reproducibility is the property most expected to
# hold. It also made release builds fail on mirror weather -- uds_bundle died on
# the v0.12.0 tag with apk aborting (SIGABRT, exit 134), and the identical re-run
# succeeded with no code change.
#
# Patching is now a deliberate ALPINE_VERSION bump rather than a build-time side
# effect. `apk add --no-cache` still resolves these packages against the live
# 3.24 index, so this is not a hermetic build; it is one that no longer rewrites
# its own pinned base.
RUN apk add --no-cache \
    git \
    build-base && \
  mix local.rebar --force && \
  mix local.hex --force

# Copy umbrella root files for dep resolution
COPY mix.exs mix.lock ./
COPY config/ config/

# Copy child mix.exs files (for dep resolution before full source copy)
COPY apps/lowendinsight/mix.exs apps/lowendinsight/mix.exs
COPY apps/lei_service/mix.exs apps/lei_service/mix.exs

RUN HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 MIX_ENV=prod mix do deps.get, deps.compile

# Copy full source
COPY apps/ apps/

RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release lei_service

# --- Runtime image ---
FROM alpine:${ALPINE_VERSION}

RUN apk update && \
    apk add --no-cache \
      bash \
      git \
      openssl \
      ca-certificates \
      libstdc++ \
      libgcc \
      libpq \
      ncurses-libs

WORKDIR /opt/app

COPY --from=builder /opt/app/_build/prod/rel/lei_service ./

CMD ["/opt/app/bin/lei_service", "start"]
