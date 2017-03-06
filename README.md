# cassandra

## What does it do
Installs a single node within a three node Cassandra cluster

built via https://github.com/mgis-architects/terraform/tree/master/azure/cassandra

This script only supports Azure currently

## Pre-req
Staged binaries on Azure File storage in the following directories

* /mnt/software/Cassandra/DataStaxEnterprise-5.0.7-linux-x64-installer.run

### Step 1 Prepare cassandra build

git clone https://github.com/mgis-architects/cassandra

cp cassandra-build.ini ~/cassandra-build.ini

Modify ~/cassandra-build.ini

### Step 2 Execute the script using the Terradata repo 

git clone https://github.com/mgis-architects/terraform

cd azure/cassandra

cp cassandra-azure.tfvars ~/cassandra-azure.tfvars

Modify ~/cassandra-azure.tfvars

terraform apply -var-file=~/cassandra-azure.tfvars

### Notes
Installation takes 15 minutes
