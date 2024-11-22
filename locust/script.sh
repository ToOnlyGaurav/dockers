#!/bin/bash

source ./../script.sh

export name="myubuntu_locust"
export binaries=""
export configs=""
export ports="8089:8089"

trigger "$@"