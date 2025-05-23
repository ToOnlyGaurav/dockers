#!/bin/bash

source ./../script.sh

export name="myubuntu_hbase"
export binaries="hbase-3.0.0-beta-1-bin.tar.gz"
#export ports="2181:2181"
export shell_command="hbase-shell"

trigger "$@"