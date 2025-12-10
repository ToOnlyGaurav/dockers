#!/bin/bash

source ./../script.sh

export name="myubuntu-noble_zk"
export binaries="apache-zookeeper-3.8.4-bin.tar.gz"
export configs="zoo.cfg"
export ports="2181:2181"
export shell_command="zkCli.sh"

trigger "$@"
