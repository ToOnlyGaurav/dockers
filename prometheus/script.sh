#!/bin/bash

source ./../script.sh

export name="myubuntu_prometheus"
export binaries="prometheus-2.43.0.linux-amd64.tar.gz"
export configs="prometheus.yml"
export ports="9090:9090"
export with_docker_compose="false"

trigger "$@"

