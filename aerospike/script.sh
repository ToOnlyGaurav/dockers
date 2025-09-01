#!/bin/bash
set -x
source ./../script.sh

# Version 7
#export name="myubuntu-noble_aerospike"
#export build_args="--build-arg AEROSPIKE_VERSION=7.2.0.4 TOOLS_VERSION=11.1.1 UBUNTU_VERSION=24.04 ARCH=aarch64 AEROSPIKE_MAJOR_VERSION=7"
#export binaries="aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64.tgz"
#export configs="aerospike_7.conf"

# Version 6
export name="myubuntu-jammy_aerospike"
export args="AEROSPIKE_VERSION=6.4.0.23 TOOLS_VERSION=10.0.0 UBUNTU_VERSION=22.04 ARCH=aarch64 AEROSPIKE_MAJOR_VERSION=6"
export binaries="aerospike-server-enterprise_6.4.0.23_tools-10.0.0_ubuntu22.04_aarch64.tgz"
export configs="aerospike_6.conf"

# Common settings
export ports="3000-3002:3000-3002"
export shell_command="aql"
export volume="aerospike"
export volume_mapping="${volume}:/opt/aerospike"



case ${1} in
  "asadm")
    docker_exec asadm
  ;;
  *)
  trigger "$@"
esac
