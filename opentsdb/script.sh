#!/bin/bash
source ./../script.sh

export name="myubuntu_opentsdb"
export binaries=""
export configs=""
export ports=""
export with_docker_compose="true"

trigger "$@"
