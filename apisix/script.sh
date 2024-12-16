#!/bin/bash

source ./../script.sh

export name="myubuntu_apisix"
export binaries=""
export configs="apisix/conf.yaml apisix/config.yaml"
export ports="8080:80"
export with_docker_compose="true"

trigger "$@"
