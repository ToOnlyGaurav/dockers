#!/bin/bash

name="myubuntu_prometheus"

case ${1} in
	"build" ) 
		echo "Building...."
		host_ip=$(ifconfig|grep 192|awk '{print $2}')
    rm -rf remote/*
    rm -rf config/*

    tar -zxvf ../binary/prometheus-2.43.0.linux-amd64.tar.gz -C ./remote/
    cp ./../configs/prometheus.yml ./config/
    sed -i -e 's/__HOST__IP__/'${host_ip}'/' ./config/prometheus.yml
		docker build . -t ${name}
	;;
	"run" )
		echo "Running..."
		set -x
		docker run -d --rm -p 9090:9090 --platform linux/x86_64 --name ${name} -it ${name}
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

