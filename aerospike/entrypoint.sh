#!/bin/bash

if [ "$1" = "asd" ]; then
  #asd --config-file /opt/aerospike/config/aerospike_7.conf
#  cat /etc/aerospike/config/aerospike.conf
  set -- "$@" --config-file /etc/aerospike/config/aerospike.conf --foreground
fi
exec "$@"