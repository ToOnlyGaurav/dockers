#!/bin/bash
set -x
source ./../script.sh

export name="myubuntu_aerospike"
export binaries="aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64.tgz"
export configs="aerospike.conf"
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
