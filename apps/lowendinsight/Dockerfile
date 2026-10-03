# Versions must match .tool-versions; scripts/check-toolchain.sh enforces it.
ARG ELIXIR_VERSION=1.20.4
ARG ERLANG_VERSION=28.5.0.6
ARG ALPINE_VERSION=3.24.1

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION} AS builder

ARG MIX_ENV=gha

ENV MIX_ENV=gha
ENV LEI_BASE_TEMP_DIR=/tmp

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

COPY lib ./lib
COPY config ./config
COPY schema ./schema
COPY mix.exs ./mix.exs
COPY scripts ./scripts
COPY mix.lock ./mix.lock
COPY entrypoint.sh /entrypoint.sh

RUN MIX_ENV=${MIX_ENV} mix do deps.get, deps.compile, compile

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]