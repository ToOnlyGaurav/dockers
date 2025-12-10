#!/bin/bash
source ./../script.sh

name="myubuntu_docker"
export binaries=""
export configs=""
export volume=""
export volume_mapping="/var/run/docker.sock:/var/run/docker.sock"

trigger "$@"

