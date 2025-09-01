#!/bin/bash
# Create /proc/self/cpuset if it doesn't exist
if [ ! -f /proc/self/cpuset ]; then
    echo "Warning: /proc/self/cpuset is missing, attempting to create"
    mkdir -p /proc/self
    echo '/' > /proc/self/cpuset 2>/dev/null || echo "Failed to create cpuset file"
fi

# Fix for cgroup v2 if needed
if [ ! -d /sys/fs/cgroup/cpu ]; then
    mkdir -p /sys/fs/cgroup/cpu 2>/dev/null || echo "Note: Could not create cgroup cpu directory"
    echo "Warning: Running with limited cgroup support"
fi

if [ "$1" = "asd" ]; then
  #asd --config-file /opt/aerospike/config/aerospike_7.conf

  set -- "$@" --config-file /etc/aerospike/config/aerospike.conf --foreground
fi
exec "$@"