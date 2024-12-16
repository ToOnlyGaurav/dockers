#!/bin/bash
BINARY_FILE_PATH="./binaries"
CONFIG_FILE_PATH="./configs"

name="name"
binaries=""
configs=""
ports=""
with_docker_compose="false"

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
    echo "with_docker_compose=${with_docker_compose}"
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

  host_ip=$(ifconfig|grep 192|awk '{print $2}'|tail -n1)
  for config in ${configs}; do
      echo "moving config ${config}"
      mkdir -p ${CONFIG_FILE_PATH}
      cp ../configs/${config} ./configs/.
      sed -i -e "s/__HOST__IP__/${host_ip}/" ./configs/${config}
    done
}


function docker_build() {
    echo "Building...."
    if [ ${with_docker_compose} == "true" ]; then
      echo "building with docker_compose"
    else
      echo "building using Dockerfile"
      docker build . -t ${name}
    fi
}

function docker_run() {
    set -x
    echo "Running...."
    if [ ${with_docker_compose} == "true" ]; then
      echo "building with docker_compose"
      docker-compose up -d # --remove-orphans
    else
      echo "building using Dockerfile"
      docker_ports=""
      if [ -n "${ports}" ]; then
        for port in ${ports}; do
          docker_ports="-p ${port} ${docker_ports}"
        done
      fi

      docker run -d --rm ${docker_ports} --platform linux/x86_64 -v ./remote:/usr/share/remote --name ${name} -it ${name}
    fi
}

function docker_exec() {
    echo "Executing..."
    id=$(docker ps -q -a --no-trunc -f name=$name$ )
    docker exec -it ${id} "${@}"
}

function docker_rm() {
    echo "Removing..."
    id=$(docker ps -q -a --no-trunc -f name=$name$ )
    docker rm ${id}
}

function docker_stop() {
    echo "Stopping..."

    if [ ${with_docker_compose} == "true" ]; then
      echo "Stopping using docker_compose"
      docker-compose stop
    else
      echo "Stopping using docker process"
      id=$(docker ps -q -a --no-trunc -f name=$name$ )
      docker stop ${id}
    fi
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
      docker_exec "bash"
    ;;

    "rm" )
      attribute_info
      docker_rm
    ;;
    "stop" )
      attribute_info
      docker_stop
    ;;
    *)
     usage
  esac
}
