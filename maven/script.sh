#!/bin/bash
source ./../script.sh

name="myubuntu_maven"
export binaries="apache-maven-3.9.9-bin.tar.gz"
export configs=""
export volume="m2"
export volume_mapping="${volume}:/root/.m2"

trigger "$@"

