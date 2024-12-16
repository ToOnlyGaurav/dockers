#!/bin/bash

source ./../script.sh

export name="myubuntu_rabbitmq"
export binaries=""
export configs="rabbitmq.conf"
export ports=""
export with_docker_compose="false"

trigger "$@"



case ${1} in
	"run" )
		echo "Running..."
		docker run --rm -d --name ${name} -p 5672:5672 -p 15672:15672 -v ./configs/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf -v ./data:/var/lib/rabbitmq rabbitmq:3-management

		echo "http://localhost:15672/"
	;;
  *)
    trigger "$@"

esac