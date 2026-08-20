# Production build image for Tetrarchy Falls (formerly Rising Constellation).
#
# Uses the official hexpm/elixir image so Erlang/Elixir are pre-installed
# — no PPA fetches, no dependency on packages.erlang-solutions.com.
#
# Pinned to the same versions the dev container resolves to: Elixir 1.17,
# OTP 27, on Ubuntu Jammy (22.04). If you bump these, also bump the dev
# image / .tool-versions / mix.exs `elixir:` requirement.
# --- resvg build stage ------------------------------------------------------
# Static-ish SVG rasterizer for the Discord news-card images, vendored
# into the release (priv/bin/resvg) so the prod HOST needs no OS
# packages for image news — no librsvg, no fontconfig (fonts load from
# priv/fonts). Built from source because upstream ships no linux
# aarch64 binary; bullseye's glibc 2.31 stays older than any host we
# deploy to, so the dynamic binary is forward-compatible. Pure Rust,
# no C deps — the layer caches until the version bumps.
FROM rust:1-bullseye AS resvg-build
ARG RESVG_VERSION=0.48.1
RUN cargo install resvg --version ${RESVG_VERSION} --locked

FROM hexpm/elixir:1.17.3-erlang-27.3.4.12-ubuntu-jammy-20260509 AS build-image

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Node 20 from NodeSource (matches dev). build-essential is still needed for
# native deps like argon2_elixir.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      build-essential libssl-dev curl ca-certificates git \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y -qq --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m rc --uid=1001

COPY ./mix* /home/rc/build/
RUN chown -R rc: /home/rc/build/
USER rc

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /home/rc/build

RUN mix deps.get

ENV MIX_ENV=prod
RUN mix deps.compile email_guard
RUN mix deps.compile

ARG APP_REVISION
ENV APP_REVISION=${APP_REVISION}
ARG BACK_ONLY
ENV BACK_ONLY=${BACK_ONLY}
ARG VUE_APP_BASE_URL
ENV VUE_APP_BASE_URL=${VUE_APP_BASE_URL}
ARG VUE_APP_APPSIGNAL_FRONT
ENV VUE_APP_APPSIGNAL_FRONT=${VUE_APP_APPSIGNAL_FRONT}

USER root
COPY . /home/rc/build/
COPY --from=resvg-build /usr/local/cargo/bin/resvg /home/rc/build/priv/bin/resvg
RUN chown -R rc: /home/rc/build/
USER rc

RUN ./build-front.sh
RUN mix release --version ${APP_REVISION}
RUN cd /home/rc/build/_build/prod/rel/ && tar -czvf /home/rc/build/rc.tar.gz rc
