# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Build context: repo root (../../)
# Usage: docker build -f apps/lowendinsight_get/Dockerfile .

ARG ALPINE_VERSION=3.18

FROM elixir:1.15.7-alpine AS builder

ARG MIX_ENV=prod

WORKDIR /opt/app

RUN apk update && \
  apk upgrade --no-cache && \
  apk add --no-cache \
    git \
    build-base && \
  mix local.rebar --force && \
  mix local.hex --force

# Copy umbrella root files for dep resolution
COPY mix.exs mix.lock ./
COPY config/ config/

# Copy child mix.exs files (for dep resolution before full source copy)
COPY apps/lowendinsight/mix.exs apps/lowendinsight/mix.exs
COPY apps/lowendinsight_get/mix.exs apps/lowendinsight_get/mix.exs

RUN HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 MIX_ENV=prod mix do deps.get, deps.compile

# Copy full source
COPY apps/ apps/

RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release lowendinsight_get

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

COPY --from=builder /opt/app/_build/prod/rel/lowendinsight_get ./

CMD ["/opt/app/bin/lowendinsight_get", "start"]
