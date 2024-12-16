#!/bin/bash

source ./../script.sh

export name="myubuntu_graphana"
export binaries=""
export configs="prometheus.yml"
export ports="8080:80"
export with_docker_compose="true"


trigger "$@"

