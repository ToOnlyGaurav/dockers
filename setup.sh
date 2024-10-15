#!/bin/bash

wget https://downloads.apache.org/zookeeper/zookeeper-3.9.2/apache-zookeeper-3.9.2-bin.tar.gz -P ./binary/
wget https://download.oracle.com/java/17/archive/jdk-17_linux-x64_bin.tar.gz -P ./binary/
wget wget https://github.com/prometheus/prometheus/releases/download/v2.43.0/prometheus-2.43.0.linux-amd64.tar.gz -P ./binary/
wget https://download.aerospike.com/artifacts/aerospike-server-enterprise/7.1.0/aerospike-server-enterprise_7.1.0.5_tools-11.0.2_ubuntu22.04_x86_64.tgz -P ./binary/
wget https://dlm.mariadb.com/3894256/MariaDB/mariadb-11.5.2/repo/debian/mariadb-11.5.2-debian-bookworm-arm64-debs.tar -P ./binary/