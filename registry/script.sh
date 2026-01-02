#!/bin/bash
source ./../script.sh

name="myubuntu-registry"
export binaries="registry_2.8.3_linux_amd64.tar.gz"
export configs="registry.yml"
export ports="5000:5000"

trigger "$@"