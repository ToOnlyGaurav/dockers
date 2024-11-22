#!/bin/bash

source ./../script.sh

export name="myubuntu_zk"
export binaries="apache-zookeeper-3.9.2-bin.tar.gz"
export configs="zoo.cfg"
export ports="2181:2181"

trigger "$@"