FROM elixir
RUN apt-get update -y
RUN curl -sL https://deb.nodesource.com/setup_20.x | bash -
RUN apt-get install -y nodejs
RUN mix local.hex --force
WORKDIR /data
ENTRYPOINT /data/dev-entrypoint.sh
