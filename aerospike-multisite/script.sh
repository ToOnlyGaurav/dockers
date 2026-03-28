#!/bin/bash
set -x
source ./../script.sh

export name="myubuntu-noble_aerospike-multisite"
export args="AEROSPIKE_VERSION=8.1.1.2 TOOLS_VERSION=12.1.1 UBUNTU_VERSION=24.04 ARCH=aarch64 AEROSPIKE_MAJOR_VERSION=8"
export binaries="aerospike-server-enterprise_8.1.1.2_tools-12.1.1_ubuntu24.04_aarch64.tgz"
export configs="aerospike_8.conf aerospike.conf.template trial-features.conf"

# Common settings
export ports="3000-3002:3000-3002"
export shell_command="aql"
export volume="aerospike_8_data"
export volume_mapping="${volume}:/etc/aerospike/data"


trigger "$@"