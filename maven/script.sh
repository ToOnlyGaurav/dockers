#!/bin/bash
source ./../script.sh

name="myubuntu_maven"
export binaries="apache-maven-3.9.9-bin.tar.gz"
export configs=""
#export volumes="m2:/root/.m2"

trigger "$@"