#!/bin/bash

#!/bin/bash

usage(){
  echo "Usage..."
  echo "sh $0 <<component>>"
  echo "sh $0 ubuntu"
  echo "sh $0 jdk"
  echo "sh $0 zookeeper"
  echo "sh $0 elasticsearch"
  echo "sh $0 prometheus"
  echo "sh $0 aerospike"
  echo "sh $0 mariadb"
  exit 1
}

function info(){
  echo "building $1"
}

function building_info(){
  echo "building $1"
}

function elasticsearch() {
  info $1
}

function zookeeper(){
  info $1
}

function docker_build(){
  building_info ${1}
  if [ ! -d "${1}" ]; then
    echo "This setup is not valid..."
    usage
  fi

  path=${1}
  cd ${path} && ./script.sh build && ./script.sh stop && ./script.sh run && ./script.sh stop && cd ..
}

function jdk(){
  info $1
}

function prometheus(){
  info $1
}

function aerospike(){
  info $1
}

function mariadb(){
  info $1

}

echo ${#}

if [ ${#} -eq 0 ]; then
  usage
fi

case ${1} in
  "all")
    docker_build ubuntu
    docker_build nginx
    docker_build jdk
    docker_build zk
    docker_build python
    docker_build aerospike
    docker_build rabbitmq
    docker_build prometheus
    docker_build opentsdb
    docker_build mariadb
    docker_build locust
    docker_build graphana
    docker_build elasticsearch
#    docker_build flamegraph
  ;;

  *)
    echo "Setting up ${1}"
    docker_build ${1}
  ;;
esac

