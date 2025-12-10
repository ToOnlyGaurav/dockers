#!/bin/bash
set -x
source ./../script.sh

LATEST="AEROSPIKE7"
#LATEST="jammy"
if [ -z "$VERSION" ]; then
  VERSION="${LATEST}"
fi

if [ "$VERSION" != "AEROSPIKE7" ] && [ "$VERSION" != "AEROSPIKE6" ]; then
  echo "Error: VERSION must be AEROSPIKE7 or AEROSPIKE6"
  exit 1
fi

if [ "$VERSION" == "AEROSPIKE7" ]; then
  export name="myubuntu-noble_aerospike"
  export args="AEROSPIKE_VERSION=7.2.0.4 TOOLS_VERSION=11.1.1 UBUNTU_VERSION=24.04 ARCH=aarch64 AEROSPIKE_MAJOR_VERSION=7"
  export binaries="aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64.tgz"
  export configs="aerospike_7.conf"
elif [ "$VERSION" == "AEROSPIKE6" ]; then
  export name="myubuntu-jammy_aerospike"
  export args="AEROSPIKE_VERSION=6.4.0.23 TOOLS_VERSION=10.0.0 UBUNTU_VERSION=22.04 ARCH=aarch64 AEROSPIKE_MAJOR_VERSION=6"
  export binaries="aerospike-server-enterprise_6.4.0.23_tools-10.0.0_ubuntu22.04_aarch64.tgz"
  export configs="aerospike_6.conf"
fi

# Common settings
export ports="3000-3002:3000-3002"
export shell_command="aql"
export volume="aerospike_7_data"
export volume_mapping="${volume}:/etc/aerospike/data"



case ${1} in
  "asadm")
    docker_exec asadm
  ;;
  *)
  trigger "$@"
esac
