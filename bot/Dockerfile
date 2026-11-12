# Bot harness build/test image. Matches the Erlang/Elixir versions used by
# the parent rc app so BEAM compatibility is consistent — if you bump
# versions in the root Dockerfile, bump them here too.
FROM hexpm/elixir:1.19.7-erlang-28.5.0.8-ubuntu-jammy-20261110 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      build-essential libssl-dev curl ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs ./
COPY config/ config/

RUN mix deps.get
RUN mix deps.compile

COPY lib/ lib/

RUN mix compile

# Default to dropping into iex when run interactively. The release target
# below is used for stress-test deployments.
CMD ["iex", "-S", "mix"]

FROM build AS release
ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix release
