# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

# Build context: repo root (../../)
# Usage: docker build -f apps/lowendinsight_get/Dockerfile .

ARG ALPINE_VERSION=3.18

FROM elixir:1.15.7-alpine AS builder

ARG MIX_ENV=prod
ARG RELEASE_ROOT_DIR=/opt/app

ENV APP_NAME=lowendinsight_get \
    APP_VSN=0.9.3 \
    MIX_ENV=${MIX_ENV} \
    RELEASE_ROOT_DIR=${RELEASE_ROOT_DIR}

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

RUN HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 MIX_ENV=${MIX_ENV} mix do deps.get, deps.compile

# Copy full source
COPY apps/ apps/

RUN MIX_ENV=${MIX_ENV} mix compile

# Distillery expects rel/config.exs at project root (File.cwd!)
RUN ln -s apps/lowendinsight_get/rel rel

RUN \
  mkdir -p /opt/built && \
  mkdir -p /opt/app/_build/prod/rel/${APP_NAME}/releases && \
  touch /opt/app/_build/prod/rel/${APP_NAME}/releases/RELEASES && \
  MIX_ENV=${MIX_ENV} mix distillery.release --verbose --env=prod && \
  cp _build/${MIX_ENV}/rel/${APP_NAME}/releases/${APP_VSN}/${APP_NAME}.tar.gz /opt/built && \
  cd /opt/built && \
  tar -xvzf ${APP_NAME}.tar.gz && \
  rm ${APP_NAME}.tar.gz

# --- Runtime image ---
FROM alpine:${ALPINE_VERSION}

RUN apk update && \
    apk add --no-cache \
      bash \
      git \
      openssl \
      libstdc++ \
      libgcc \
      libpq \
      ncurses-libs

ENV REPLACE_OS_VARS=true \
    APP_NAME=lowendinsight_get \
    ERL_AFLAGS="-proto_dist inet6_tcp" \
    DATABASE_URL="ecto://postgres:postgres@localhost/lowendinsight_get_prod" \
    REDIS_URL="redis://localhost:6379"

WORKDIR /opt/app

COPY --from=builder /opt/built .

CMD trap 'exit' INT; /opt/app/bin/${APP_NAME} foreground
