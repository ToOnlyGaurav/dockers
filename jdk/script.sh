#!/bin/bash

name="myubuntu_jdk"

case ${1} in
	"build" ) 
		echo "Building...."
		docker build . -t ${name}
	;;
	"run" )
		echo "Running..."
		docker run -d --rm --platform linux/x86_64 --name ${name} -it ${name}
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

