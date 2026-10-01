# Production build for Tetrarchy Falls (formerly Rising Constellation).
#
# Output: the `artifacts` stage holds rc.tar.gz (the mix release) and
# vue.tar.gz (the nginx docroot); export it with
#
#   docker buildx build --target artifacts --output type=local,dest=build ...
#
# The build is split into stages so BuildKit runs the independent pieces at
# the same time. Elixir compiles its dependencies one at a time on a single
# core, so that chain sets the wall-clock; the node builds and the resvg
# build run alongside it instead of queueing behind it.
#
#   resvg-build ───────────────────────┐
#   toolchain ─ deps-src ─ deps ───────┴─ app-src ─┐
#                  └ assets-deps ─ assets ─────────┴─ app-* ─┬─ release ─┬─ artifacts
#   vue-deps ─ vue ──────────────────────────────────────────┴─ web ─────┘
#
# Two kinds of stage:
#   * dependency stages (resvg-build, toolchain, deps-src, deps,
#     assets-deps, vue-deps) read only this file and the lockfiles (and
#     the optional dependency cache, see the depscache stage);
#   * source stages (assets, vue, app-*, release, web-*) see the repo.
# Every source stage copies the WHOLE build context, so none of them can
# see less of the tree than a single-stage build would.
#
# Elixir/OTP are pinned to what the dev container resolves to: Elixir 1.17,
# OTP 27, on Ubuntu Jammy (22.04). If you bump these, also bump the dev
# image / .tool-versions / mix.exs `elixir:` requirement.

# true = backend-only release: the assets, vue and web stages are skipped
# and the release ships an empty priv/static (nginx keeps serving the
# previous front end).
ARG BACK_ONLY=false

# true = also write deps-cache.tar.gz (see the depscache stage).
ARG DEPS_CACHE_SAVE=false

# --- resvg -------------------------------------------------------------------
# Static-ish SVG rasterizer for the Discord news-card images, vendored
# into the release (priv/bin/resvg) so the prod HOST needs no OS
# packages for image news — no librsvg, no fontconfig (fonts load from
# priv/fonts). Built from source because upstream ships no linux
# aarch64 binary; bullseye's glibc 2.31 stays older than any host we
# deploy to, so the dynamic binary is forward-compatible. Pure Rust,
# no C deps, so the slim image is enough (it builds the same binary, byte
# for byte, as the full one, and is half the download).
FROM rust:1-slim-bullseye AS resvg-build
ARG RESVG_VERSION=0.48.1
RUN cargo install resvg --version ${RESVG_VERSION} --locked

# --- toolchain ---------------------------------------------------------------
# The official hexpm/elixir image has Erlang/Elixir pre-installed — no PPA
# fetches. build-essential is for native deps like argon2_elixir, git for
# git-sourced deps, pigz to gzip the tarballs on every core.
FROM hexpm/elixir:1.17.3-erlang-27.3.4.12-ubuntu-jammy-20260509 AS toolchain

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV MIX_ENV=prod

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      build-essential libssl-dev ca-certificates git pigz \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m rc --uid=1001 \
 && install -d -o rc -g rc /home/rc/build
USER rc
WORKDIR /home/rc/build

RUN mix local.hex --force && mix local.rebar --force

# --- depscache: optional dependency cache ------------------------------------
# Compiling the dependencies is most of a build (~105s of ~165s on the
# Graviton builder) and only changes with mix.lock. A build may be handed
# the fetched + compiled dependencies of an earlier one:
#
#   --build-context depscache=<dir holding deps-cache.tar.gz>
#
# Without that flag this empty stage stands in and everything is built from
# scratch. The tarball holds ONLY deps/ and the dependencies' _build/ —
# never the application, which every build compiles from the source it was
# given. Mix still checks it against mix.lock: a dependency whose locked
# version differs is refetched and recompiled, one that is missing is
# rebuilt, and a tarball that does not unpack is ignored.
# deploy/bin/remote-build.sh keeps one per (Dockerfile, mix.exs, mix.lock)
# on the operator's machine and only hands over an exact match;
# DEPS_CACHE_SAVE=true makes the build write a fresh one next to the
# release tarballs.
FROM scratch AS depscache

# --- deps-src: fetched dependency sources ------------------------------------
# Its own stage because the Phoenix asset build needs deps/phoenix* and
# should not wait for the dependencies to compile.
FROM toolchain AS deps-src
COPY --chown=rc:rc ./mix* /home/rc/build/
RUN --mount=type=bind,from=depscache,target=/depscache \
    if [ -f /depscache/deps-cache.tar.gz ]; then \
      echo "restoring dependency cache"; \
      if tar -I pigz -xpf /depscache/deps-cache.tar.gz; then \
        touch /home/rc/.deps-cache-restored; \
      else \
        echo "dependency cache unreadable -- building dependencies from scratch"; \
        rm -rf deps _build; \
      fi; \
    fi
RUN mix deps.get --only prod

# --- deps: compiled dependencies ---------------------------------------------
# Skipped over a restored cache: `mix deps.compile` restarts rebar3 for each
# of the ~20 Erlang dependencies even when there is nothing to do (~26s),
# and it is not what keeps a cache honest. `mix deps.get` above refetches
# whatever differs from mix.lock and marks it for compilation, and the
# application's own compile (phx.digest / release) builds every dependency
# that is marked or missing before it compiles anything else.
FROM deps-src AS deps
RUN if [ -f /home/rc/.deps-cache-restored ]; then \
      echo "dependencies restored from the cache"; \
    else \
      mix deps.compile email_guard && mix deps.compile; \
    fi

# The application's own _build directory (an empty lock file at this point)
# stays out, so the tarball is dependencies and nothing else.
FROM deps AS cache-save-true
RUN mkdir /home/rc/cache-out \
 && tar -I pigz -cf /home/rc/cache-out/deps-cache.tar.gz \
      --exclude='_build/*/lib/rc' deps _build

FROM toolchain AS cache-save-false
RUN mkdir /home/rc/cache-out

# --- assets: Phoenix-side JS/CSS (landing, admin, help pages) ----------------
# Node 20 (matches dev).
FROM node:20-bookworm-slim AS assets-deps
WORKDIR /home/rc/build
COPY assets/package.json assets/package-lock.json assets/
# package.json points at these with file:../deps/...
COPY --from=deps-src /home/rc/build/deps/phoenix deps/phoenix
COPY --from=deps-src /home/rc/build/deps/phoenix_html deps/phoenix_html
COPY --from=deps-src /home/rc/build/deps/phoenix_live_view deps/phoenix_live_view
RUN npm ci --prefix assets

FROM assets-deps AS assets
COPY . /home/rc/build/
ENV NODE_ENV=production
# SVG sprite for the public help pages, built from front/src/icons.
RUN npm run help-icons --prefix assets
# webpack 4 hits OpenSSL 3's "unsupported" error without the legacy
# provider flag (same workaround as the Vue build below and the dev
# watcher in config/dev.exs). Writes priv/static.
RUN NODE_OPTIONS="--openssl-legacy-provider" npm run deploy --prefix assets

# --- vue: the game SPA -------------------------------------------------------
FROM node:20-bookworm-slim AS vue-deps
WORKDIR /home/rc/build
COPY front/package.json front/package-lock.json front/
RUN npm ci --prefix front

FROM vue-deps AS vue
COPY . /home/rc/build/
ARG APP_REVISION
ARG VUE_APP_BASE_URL
RUN if [ -z "${VUE_APP_BASE_URL}" ]; then \
      echo "error: VUE_APP_BASE_URL is required for a prod Vue build" >&2; \
      echo "  example: --build-arg VUE_APP_BASE_URL=https://your-domain.example" >&2; \
      exit 1; \
    fi
# VUE_APP_GIT_SHA is the bundle's own revision (front/src/utils/build.js),
# compared by the client with the live server's (GET /api/version). Same
# git hash the release is stamped with (deploy/release.sh → APP_REVISION,
# priv/VERSION).
RUN cd front \
 && NODE_ENV=production \
    VUE_APP_BASE_URL="${VUE_APP_BASE_URL}" \
    VUE_APP_GIT_SHA="${APP_REVISION:-dev}" \
    NODE_OPTIONS="--openssl-legacy-provider" \
    npm run build

# --- app: the Elixir application ---------------------------------------------
FROM deps AS app-src
ARG APP_REVISION
ENV APP_REVISION=${APP_REVISION}
COPY --chown=rc:rc . /home/rc/build/
COPY --chown=rc:rc --from=resvg-build /usr/local/cargo/bin/resvg /home/rc/build/priv/bin/resvg

# Full build: compile with the Phoenix assets in place and fingerprint
# them. The digested tree moves to the nginx docroot staging dir — its
# shape (www-root/asylamba/{static,front}) is what nginx on the prod host
# expects, see deploy/nginx/rc.conf.example.
FROM app-src AS app-backonly-false
COPY --chown=rc:rc --from=assets /home/rc/build/priv/static /home/rc/build/priv/static
RUN mix phx.digest
# Preserve the digest manifest in the release so Routes.static_path
# generates fingerprinted URLs in Phoenix-rendered pages (landing,
# admin, press kit). Without it, Phoenix logs "Could not warm up
# static assets" at boot and falls back to un-hashed asset paths,
# which nginx still serves but without the immutable-cache rule
# matching — so cache busting silently degrades on every release.
RUN mkdir -p /home/rc/www-root/asylamba \
 && mv priv/static /home/rc/www-root/asylamba/static \
 && mkdir -p priv/static \
 && cp /home/rc/www-root/asylamba/static/cache_manifest.json priv/static/cache_manifest.json

# Backend-only build: no assets; `mix release` below does the compile.
FROM app-src AS app-backonly-true

FROM app-backonly-${BACK_ONLY} AS release
RUN mix release --version ${APP_REVISION}
RUN tar -I pigz -cf /home/rc/build/rc.tar.gz -C /home/rc/build/_build/prod/rel rc

# --- web: the nginx docroot tarball ------------------------------------------
# Members are home/rc/www-root/asylamba/...; deploy.sh strips the first two
# components on the host.
FROM app-backonly-false AS web-backonly-false
COPY --chown=rc:rc --from=vue /home/rc/build/front/dist /home/rc/www-root/asylamba/front
RUN mkdir /home/rc/out \
 && tar -I pigz -cf /home/rc/out/vue.tar.gz /home/rc/www-root/asylamba

FROM toolchain AS web-backonly-true
RUN mkdir /home/rc/out

FROM web-backonly-${BACK_ONLY} AS web

FROM cache-save-${DEPS_CACHE_SAVE} AS cache-save

# --- artifacts ---------------------------------------------------------------
FROM scratch AS artifacts
COPY --from=release /home/rc/build/rc.tar.gz /
COPY --from=web /home/rc/out/ /
COPY --from=cache-save /home/rc/cache-out/ /
