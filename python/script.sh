#!/bin/bash
set -x
source ./../script.sh

name="myubuntu-python"

export binaries=""
export configs=""
export ports=""
export shell_command="python3"
export volume_mapping="$(pwd)/scripts:/scripts"

trigger "$@"
