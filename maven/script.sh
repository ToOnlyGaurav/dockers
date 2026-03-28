#!/bin/bash
source ./../script.sh

name="myubuntu_maven"
export binaries="apache-maven-3.9.9-bin.tar.gz"
export configs=""
export volume="m2"
export volume_mapping="${volume}:/root/.m2"

if [ -d "$HOME/gitlab/active" ]; then
  volume_mapping="$volume_mapping $HOME/gitlab/active:/usr/share/active"
fi

#mvn clean install -T 1C -Dos.detected.classifier=linux-x86_64 -Dos.detected.arch=x86_64 -Dos.detected.name=linux

trigger "$@"

