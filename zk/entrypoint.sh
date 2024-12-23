#!/bin/bash
# Allow the container to be started with `--user`
if [[ "$1" = 'zkServer.sh' && "$(id -u)" = '0' ]]; then
    exec gosu zookeeper "$0" "$@"
fi

# Write myid only if it doesn't exist
if [[ ! -f "$ZOO_DATA_DIR/myid" ]]; then
    echo "${ZOO_MY_ID:-1}" > "$ZOO_DATA_DIR/myid"
fi

echo "$0"
echo "$1"

echo "$(id -u)"

echo "$@"

exec "$@"