#!/bin/bash

source ./../script.sh

export name="myubuntu_locust"
export binaries=""
export configs=""
export ports="8089:8089"
export network="as-multisite"
export volume_mapping="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/locustfiles:/locustfiles"

  trigger "$@"