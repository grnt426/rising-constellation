#!/bin/bash
set -xe

# Wait for postgres to accept connections (compose healthcheck should already
# have gated this, but belt-and-braces for non-compose runs).
until pg_isready -h "${RDBMS_HOST:-localhost}" -U postgres >/dev/null 2>&1 ; do
    echo "waiting for postgres at ${RDBMS_HOST:-localhost}..."
    sleep 1
done

mkdir -p /var/lib/rc-state

mix deps.get

if [ ! -e /var/lib/rc-state/seeded ] ; then
    mix ecto.create
    mix ecto.migrate
    mix run priv/repo/seeds.exs
    touch /var/lib/rc-state/seeded
else
    mix ecto.migrate
fi

make ni

exec mix phx.server
