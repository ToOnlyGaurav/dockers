#!/bin/bash

name="mymariadb"

case ${1} in
	"build" ) 
		echo "Building...."
    rm -rf config/*.yml
    cp ./../configs/mariadb/*.cnf ./config/

		docker-compose up -d
	;;
	"run" )
		echo "Running..."
#		docker run -d --rm --platform linux/x86_64 --name ${name} -it ${name}
    docker-compose up -d
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
#		id=$(docker ps -q -a --no-trunc -f name=$name )
#		docker stop ${id}
		docker-compose down
	;;

esac

