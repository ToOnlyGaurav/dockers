#!/bin/bash

source ./../script.sh

export name="myubuntu_mymariadb"
export binaries=""
export configs="mariadb.cnf"
export ports="3306:3306"
export with_docker_compose="true"

case ${1} in
  "shell")
    docker_exec mariadb --user root -pmy-secret-pw
  ;;
  *)
  trigger "$@"
esac

