#!/bin/bash
set -x
source ./../script.sh

name="myubuntu-notebook"

export binaries=""
export configs=""
export ports="8888:8888"
export shell_command="python3"
export volume_mapping="./remote/:/remote"
trigger "$@"
