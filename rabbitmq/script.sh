#!/bin/bash

name="myubuntu_rabbitmq"

case ${1} in
	"build" ) 
		echo "Building...."
		cp ./../configs/rabbitmq.conf ./config/.
#		docker build . -t ${name}
	;;
	"run" )
		echo "Running..."
		docker run --rm -d --name ${name} -p 5672:5672 -p 15672:15672 -v ./config/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf -v ./data:/var/lib/rabbitmq rabbitmq:3-management

		echo "http://localhost:15672/"
	;;

	"exec" )
		echo "Executing..."
		id=$(docker ps -q -a --no-trunc -f name=$name )
		docker exec -it ${id} bash
	;;

	"rm" )
		id=$(docker ps -q -a --no-trunc -f name=$name )
		docker rm ${id}
	;;
	"stop" )
		echo "Stopping..."
		id=$(docker ps -q -a --no-trunc -f name=$name )
		docker stop ${id}
	;;

esac

