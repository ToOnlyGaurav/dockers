#!/bin/bash

usage(){
  echo "Usage..."
  echo "sh $0 <<component>>"

  echo "sh $0 jdk"
  echo "sh $0 maven"
  echo "sh $0 locust"
  echo "sh $0 zookeeper"
  echo "sh $0 elasticsearch"
  echo "sh $0 prometheus"
  echo "sh $0 aerospike"
  echo "sh $0 mariadb"
  echo "sh $0 hbase"
  exit 1
}

elasticsearch() {
#  https://www.elastic.co/downloads/elasticsearch
  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.17.0-linux-aarch64.tar.gz -P ./binary/
#  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.15.2-linux-x86_64.tar.gz -P ./binary/
#  wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.15.2-linux-x86_64.tar.gz.sha512 -P ./binary/
#  cd ./binary && shasum -a 512 -c elasticsearch-8.15.2-linux-x86_64.tar.gz.sha512 && cd ..
}

zookeeper(){
  wget https://downloads.apache.org/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz -P ./binary/
}
jdk(){
  wget https://download.oracle.com/java/17/archive/jdk-17_linux-x64_bin.tar.gz -P ./binary/
  wget https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_linux-aarch64_bin.tar.gz -P ./binary/
}

prometheus(){
  wget wget https://github.com/prometheus/prometheus/releases/download/v2.43.0/prometheus-2.43.0.linux-amd64.tar.gz -P ./binary/
}

aerospike(){
#  https://aerospike.com/download/server/enterprise/
  wget https://download.aerospike.com/artifacts/aerospike-server-enterprise/7.2.0/aerospike-server-enterprise_7.2.0.4_tools-11.1.1_ubuntu24.04_aarch64.tgz -P ./binary/
}

mariadb(){
#  https://mariadb.com/downloads/
#  wget https://dlm.mariadb.com/3964818/MariaDB/mariadb-11.6.2/repo/ubuntu/mariadb-11.6.2-ubuntu-jammy-amd64-debs.tar -P ./binary/
#  wget https://archive.mariadb.org//mariadb-11.6.2/galera-26.4.20/bintar/galera-26.4.20-i686.tar.gz -P ./binary/
  wget https://dlm.mariadb.com/3964815/MariaDB/mariadb-11.6.2/repo/ubuntu/mariadb-11.6.2-ubuntu-noble-arm64-debs.tar  -P ./binary/
}

hbase(){
  wget https://dlcdn.apache.org/hbase/3.0.0-beta-1/hbase-3.0.0-beta-1-bin.tar.gz -P ./binary/
}

maven(){
  wget https://dlcdn.apache.org/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz -P ./binary/
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
  "hbase")
    echo "Setting up ${1}"
    hbase
  ;;
  "maven")
    echo "Setting up ${1}"
    maven
  ;;
  "ubuntu")
    echo "Setting up ${1}"
    echo "Noting needed"
  ;;
  "rabbitmq")
    echo "Setting up ${1}"
    echo "Noting needed"
  ;;
  "all")
    ubuntu
    jdk
    maven
    python
    nginx
    zookeeper
    elasticsearch
    prometheus
    opentsdb
    aerospike
    mariadb
    hbase
    locust
    graphana
    rabbitmq
    flamegraph
    apisix
  ;;
  *) usage
esac

