#!/bin/bash
set -x
source ./../script.sh

#export name="myubuntu-noble_python"
export name="myubuntu-jammy_python"

export binaries=""
export configs=""
export ports=""
export shell_command="python3"

trigger "$@"
