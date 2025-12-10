# Repository for list of docker images
There are scenarios where you need different setups like ubuntu, nginx, mariaDB etc. There are vanila setups available in the market however situations where you need customisations or you want to use as it. This repo will help where we are having simple packages and installations. These are mainaly for Mac Arm achitecture  

## Setup approach
We are setting up the packages in which one might setup on dedicated VMs. For example, using the JDK binary to install java, or ZK binary to setup zookeeper.
First run the setup script to download required binaries

Hence we need few binaries to get started.

### Setup the specific binary
```
bash ./setup.sh <<package name>>
```
## exmaple
```
bash ./setup.sh jdk
```

### Convension 
One convension we are following that all the images are prefixed with `my` keyword.
### How to use 
To use the docker we can follow below steps.
<br/>Navigate to the specific folder

<br/> Run the setup script with right arguments

* build -> to build the docker image
* run   -> to run the docker image
* exec  -> to execute the docker image and open bash
* stop  -> to stop the process
* rm    -> to remove the process

### For Example, below the steps to use ubuntu
```
cd ubuntu
```

```
./script.sh build
```

```
./script.sh run
```

```
./script.sh exec
```

```
./script.sh stop
```

```
./script.sh rm
```

### Supported dockers in this repo

* ubuntu
* jdk
* nginx
* zk
* python
* locust
* aerospike
* apisix
* elasticsearch
* graphana
* mariaDB
* openTSDB
* prometheus
* rabbitmq
* hbase - WIP

### Wishlist


update /etc/docker/daemon.json in-case one faces dns issue
docker image prune
lsof -i :3002




