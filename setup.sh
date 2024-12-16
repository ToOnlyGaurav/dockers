#!/bin/bash

usage(){
  echo "Usage..."
  echo "sh $0 <<component>>"
  echo "sh $0 jdk"
  echo "sh $0 zookeeper"
  echo "sh $0 elasticsearch"
  echo "sh $0 prometheus"
  echo "sh $0 aerospike"
  echo "sh $0 mariadb"
  exit 1
}

elasticsearch() {
  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.15.2-linux-x86_64.tar.gz -P ./binary/
  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.15.2-linux-x86_64.tar.gz.sha512 -P ./binary/
  cd ./binary && shasum -a 512 -c elasticsearch-8.15.2-linux-x86_64.tar.gz.sha512 && cd ..
}

zookeeper(){
  wget https://downloads.apache.org/zookeeper/zookeeper-3.9.2/apache-zookeeper-3.9.2-bin.tar.gz -P ./binary/
}
jdk(){
  wget https://download.oracle.com/java/17/archive/jdk-17_linux-x64_bin.tar.gz -P ./binary/
}

prometheus(){
  wget wget https://github.com/prometheus/prometheus/releases/download/v2.43.0/prometheus-2.43.0.linux-amd64.tar.gz -P ./binary/
}

aerospike(){
  wget https://download.aerospike.com/artifacts/aerospike-server-enterprise/7.1.0/aerospike-server-enterprise_7.1.0.5_tools-11.0.2_ubuntu22.04_x86_64.tgz -P ./binary/
}

mariadb(){
#  wget https://dlm.mariadb.com/3964818/MariaDB/mariadb-11.6.2/repo/ubuntu/mariadb-11.6.2-ubuntu-jammy-amd64-debs.tar -P ./binary/
  wget https://archive.mariadb.org//mariadb-11.6.2/galera-26.4.20/bintar/galera-26.4.20-i686.tar.gz -P ./binary/
}

if [ ${#} -eq 0 ]; then
  usage
fi

case ${1} in
  "jdk" )
    echo "Setting up ${1}"
    jdk
  ;;
  "zookeeper" )
    echo "Setting up ${1}"
    zookeeper
    ;;
  "elasticsearch")
    echo "Setting up ${1}"
    elasticsearch
  ;;
  "prometheus")
    echo "Setting up ${1}"
    prometheus
  ;;
  "aerospike")
    echo "Setting up ${1}"
    aerospike
  ;;
  "mariadb")
    echo "Setting up ${1}"
    mariadb
  ;;
  "all")
    jdk
    zookeeper
    elasticsearch
    prometheus
    aerospike
    mariadb
  ;;
  *) usage
esac

