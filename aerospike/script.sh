#!/bin/bash

name="myubuntu_aerospike"

case ${1} in
	"build" ) 
		echo "Building...."
    rm -rf ./config/*
    rm -rf ./remote/*
    tar -zxvf ../binary/aerospike-server-enterprise_7.1.0.5_tools-11.0.2_ubuntu22.04_x86_64.tgz -C ./remote/

    cp ./../configs/aerospike.conf ./config/

#		docker-compose up -d
		 docker build . -t ${name}
	;;
	"run" )
		echo "Running..."
		set -x
		docker run -d --rm --platform  linux/x86_64 --name ${name} -it ${name}
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

