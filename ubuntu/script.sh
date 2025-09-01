#!/bin/bash
source ./../script.sh

LATEST="noble"
#LATEST="jammy"
if [ -z "$VERSION" ]; then
  VERSION="${LATEST}"
fi

export args="VERSION=${VERSION}"

name="myubuntu-${VERSION}"
export binaries=""
export configs=""

trigger "$@"