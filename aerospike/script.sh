#!/bin/bash

source ./../script.sh

export name="myubuntu_aerospike"
export binaries="aerospike-server-enterprise_7.1.0.5_tools-11.0.2_ubuntu22.04_x86_64.tgz"
export configs="aerospike.conf"
export ports="3000-3002:3000-3002"

trigger "$@"