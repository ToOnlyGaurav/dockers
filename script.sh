#!/bin/bash
BINARY_FILE_PATH="./binaries"
CONFIG_FILE_PATH="./configs"

name="name"
binaries=""
configs=""
ports=""

usage(){
  echo "Usage..."
  echo "sh $0 build|run|run -f|exec|run|stop"
  exit 1
}

if [ ${#} -eq 0 ]; then
  usage
fi

function attribute_info() {
    echo "name=${name}"
    echo "binaries=${binaries}"
    echo "configs=${configs}"
    echo "ports=${ports}"
}

function remote_copy(){
  echo "Cleaning remote directory..."
  rm -rf ${BINARY_FILE_PATH}
  rm -rf ${CONFIG_FILE_PATH}

  echo "Copying binary..."
  for binary in ${binaries}; do
    echo "moving binary ${binary}"
    mkdir -p ${BINARY_FILE_PATH}
    tar -zxvf ../binary/${binary} -C ./binaries/
  done

  for config in ${configs}; do
      echo "moving config ${config}"
      mkdir -p ${CONFIG_FILE_PATH}
      cp ../configs/${config} ./configs/.
    done
}

function docker_build() {
    echo "Building...."
    docker build . -t ${name}
}

function docker_run() {
    set -x
    echo "Running...."
    docker_ports=""
    if [ -n "${ports}" ]; then
      for port in ${ports}; do
        docker_ports="-p ${port} ${docker_ports}"
      done
    fi

    docker run -d --rm ${docker_ports} --platform linux/x86_64 --name ${name} -it ${name}
}

function docker_exec() {
    echo "Executing..."
    id=$(docker ps -q -a --no-trunc -f name=$name$ )
    docker exec -it ${id} bash
}

function docker_rm() {
    echo "Removing..."
    id=$(docker ps -q -a --no-trunc -f name=$name$ )
    docker rm ${id}
}

function docker_stop() {
    echo "Stopping..."
		id=$(docker ps -q -a --no-trunc -f name=$name$ )
		docker stop ${id}
}

function trigger() {
  case ${1} in
    "build" )
      attribute_info
      remote_copy
      docker_build
    ;;
    "run" )
      attribute_info
      if [ ${#} -eq 2 ] && [ ${2} == "-f" ]; then
        docker_stop
      fi
      docker_run
    ;;

    "exec" )
      attribute_info
      docker_exec
    ;;

    "rm" )
      attribute_info
      docker_rm
    ;;
    "stop" )
      attribute_info
      docker_stop
    ;;
  esac
}
