#!/bin/bash

source ./../script.sh

export name="myubuntu_es"
export binaries="elasticsearch-8.15.2-linux-x86_64.tar.gz"
export configs="elasticsearch.yml"
export ports="9200:9200 9300:9300"

trigger "$@"