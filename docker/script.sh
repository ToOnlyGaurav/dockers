#!/bin/bash
source ./../script.sh

name="myubuntu_docker"
export binaries=""
export configs=""
export volume="m2"
export volume_mapping="/var/run/docker.sock:/var/run/docker.sock ${volume}:/root/.m2"

if [ -d "$HOME/gitlab/active" ]; then
  volume_mapping="$volume_mapping $HOME/gitlab/active:/usr/share/active"
fi

[ $# -eq 0 ] && usage
trigger "$@"
#mvn clean install -T 1C -Dos.detected.classifier=linux-x86_64 -Dos.detected.arch=x86_64 -Dos.detected.name=linux
