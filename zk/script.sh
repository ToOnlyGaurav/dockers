#!/bin/bash

name="myubuntu_zk"

case ${1} in
	"build" ) 
		echo "Building...."
		mkdir -p remote
		rm -rf remote/*

		tar -zxvf ../binary/jdk-17_linux-x64_bin.tar.gz -C ./remote/
		tar -zxvf ../binary/apache-zookeeper-3.9.2-bin.tar.gz -C ./remote/
		cp ../configs/zoo.cfg ./remote/apache-zookeeper-3.9.2-bin/conf/.
		docker build . -t ${name}
	;;
	"run" )
		echo "Running..."
		docker run -d --rm -p 2181:2181 --platform linux/x86_64 --name ${name} -it ${name}
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

