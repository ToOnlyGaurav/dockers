#!/bin/bash

if [ "$1" = "asd" ]; then
  #asd --config-file /etc/aerospike/aerospike.conf

  set -- "$@" --config-file /etc/aerospike/aerospike.conf --foreground
fi
exec "$@"