#!/bin/bash

if [ "$1" = "asd" ]; then
  #asd --config-file /opt/aerospike/config/aerospike.conf

  set -- "$@" --config-file /opt/aerospike/config/aerospike.conf --foreground
fi
exec "$@"