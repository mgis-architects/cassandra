#!/bin/bash
#########################################################################################
## Cassandra
#########################################################################################
# Installs Cassandra Open source
# built via https://github.com/mgis-architects/terraform/tree/master/azure/oracledb
# This script only supports Azure currently, mainly due to the disk persistence method
#
# USAGE:
#
#    sudo cassandra-build.sh ~/cassandra-build.ini
#
# USEFUL LINKS: 
# 
# docs:    
# install: 
# useful:
#
#########################################################################################

g_prog=cassandra-build
RETVAL=0

######################################################
## defined script variables
######################################################
STAGE_DIR=/tmp/$g_prog/stage
LOG_DIR=/var/log/$g_prog
LOG_FILE=$LOG_DIR/${prog}.log.$(date +%Y%m%d_%H%M%S_%N)
INI_FILE=$LOG_DIR/${g_prog}.ini

THISDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCR=$(basename "${BASH_SOURCE[0]}")
THIS_SCRIPT=$THISDIR/$SCR

######################################################
## log()
##
##   parameter 1 - text to log
##
##   1. write parameter #1 to current logfile
##
######################################################
function log ()
{
    if [[ -e $LOG_DIR ]]; then
        echo "$(date +%Y/%m/%d_%H:%M:%S.%N) $1" >> $LOG_FILE
    fi
}

######################################################
## fatalError()
##
##   parameter 1 - text to log
##
##   1.  log a fatal error and exit
##
######################################################
function fatalError ()
{
    MSG=$1
    log "FATAL: $MSG"
    echo "ERROR: $MSG"
    exit -1
}

function installRPMs()
{
    INSTALL_RPM_LOG=$LOG_DIR/yum.${g_prog}_install.log.$$

    STR=""
    STR="$STR install wget zip unzip strace expect cifs-utils java-1.8.0-openjdk"
    
    yum makecache fast
    
    echo "installRPMs(): to see progress tail $INSTALL_RPM_LOG"
    if ! yum -y install $STR > $INSTALL_RPM_LOG
    then
        fatalError "installRPMs(): failed; see $INSTALL_RPM_LOG"
    fi
}

function addLimits()
{
    cp /etc/security/limits.conf /etc/security/limits.conf.preCassandra
    
    cat >> /etc/security/limits.conf << EOFaddLimits
*           soft    nproc     16384
*           hard    nproc     16384
EOFaddLimits
}

function fixSwap()
{
    cat /etc/waagent.conf | while read LINE
    do
        if [ "$LINE" == "ResourceDisk.EnableSwap=n" ]; then
                LINE="ResourceDisk.EnableSwap=y"
        fi

        if [ "$LINE" == "ResourceDisk.SwapSizeMB=2048" ]; then
                LINE="ResourceDisk.SwapSizeMB=14000"
        fi
        echo $LINE
    done > /tmp/waagent.conf
    /bin/cp /tmp/waagent.conf /etc/waagent.conf
    systemctl restart waagent.service
}

function fixTime() {
    timedatectl set-timezone UTC
    date
}

createFilesystem()
{
    # createFilesystem /u01 $l_disk $diskSectors  
    # size is diskSectors-128 (offset)

    local p_filesystem=$1
    local p_disk=$2
    local p_sizeInSectors=$3
    local l_sectors
    local l_layoutFile=$LOG_DIR/sfdisk.${g_prog}_install.log.$$
    
    if [ -z $p_filesystem ] || [ -z $p_disk ] || [ -z $p_sizeInSectors ]; then
        fatalError "createFilesystem(): Expected usage mount,device,numsectors, got $p_filesystem,$p_disk,$p_sizeInSectors"
    fi
    
    let l_sectors=$p_sizeInSectors-128
    
    cat > $l_layoutFile << EOFsdcLayout
# partition table of /dev/sdc
unit: sectors

/dev/sdc1 : start=     128, size=  ${l_sectors}, Id= 83
/dev/sdc2 : start=        0, size=        0, Id= 0
/dev/sdc3 : start=        0, size=        0, Id= 0
/dev/sdc4 : start=        0, size=        0, Id= 0
EOFsdcLayout

    set -x # debug has been useful here

    if ! sfdisk $p_disk < $l_layoutFile; then fatalError "createFilesystem(): $p_disk does not exist"; fi
    
    sleep 4 # add a delay - experiencing occasional "cannot stat" for mkfs
    
    log "createFilesystem(): Dump partition table for $p_disk"
    fdisk -l 
    
    if ! mkfs.ext4 ${p_disk}1; then fatalError "createFilesystem(): mkfs.ext4 ${p_disk}1"; fi
    
    if ! mkdir -p $p_filesystem; then fatalError "createFilesystem(): mkdir $p_filesystem failed"; fi
    
    if ! chmod 755 $p_filesystem; then fatalError "createFilesystem(): chmod $p_filesystem failed"; fi
    
    if ! mount ${p_disk}1 $p_filesystem; then fatalError "createFilesystem(): mount $p_disk $p_filesytem failed"; fi

    log "createFilesystem(): Dump blkid"
    blkid
    
    if ! blkid | egrep ${p_disk}1 | awk '{printf "%s\t'${p_filesystem}' \t ext4 \t defaults \t 1 \t2\n", $2}' >> /etc/fstab; then fatalError "createFilesystem(): fstab update failed"; fi

    log "createFilesystem() fstab success: $(grep $p_disk /etc/fstab)"

    set +x    
}

function allocateStorage() 
{
    local l_disk
    local l_size
    local l_sectors
    local l_hasPartition

    for l_disk in /dev/sd? 
    do
         l_hasPartition=$(( $(fdisk -l $l_disk | wc -l) != 6 ? 1 : 0 ))
        # only use if it doesnt already have a blkid or udev UUID
        if [ $l_hasPartition -eq 0 ]; then
            let l_size=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $5}'`/1024/1024/1024
            let l_sectors=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $7}'`
            
            if [ $u01_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating /u01 on $l_disk"
                createFilesystem /u01 $l_disk $l_sectors
            fi
        fi
    done   
}

function mountMedia() {

    if [ -f ${cassandraMediaLocation}/${cassandraMedia} ]; then
        log "mountMedia(): Filesystem already mounted"
    else
        umount /mnt/software
    
        mkdir -p /mnt/software
        
        eval `grep mediaStorageAccountKey $INI_FILE`
        eval `grep mediaStorageAccount $INI_FILE`
        eval `grep mediaStorageAccountURL $INI_FILE`

        l_str=""
        if [ -z $mediaStorageAccountKey ]; then
            l_str+="mediaStorageAccountKey not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccount ]; then
            l_str+="mediaStorageAccount not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccountURL ]; then
            l_str+="mediaStorageAccountURL not found in $INI_FILE; "
        fi
        if ! [ -z $l_str ]; then
            fatalError "mountMedia(): $l_str"
        fi

        cat > /etc/cifspw << EOF1
username=${mediaStorageAccount}
password=${mediaStorageAccountKey}
EOF1

        cat >> /etc/fstab << EOF2
//${mediaStorageAccountURL}     /mnt/software   cifs    credentials=/etc/cifspw,vers=3.0,gid=54321      0       0
EOF2

        mount -a
        
    fi
    
}

installCassandra()
{
    local l_log=$LOG_DIR/$g_prog.install.$$.installCassandra.log
    
    cat > /tmp/dseinstall.properties << EOF_PROPERTIES
prefix=/u01/datastax/dse
cassandra_yaml_template=/u01/datastax/dse/templates/cassandra.yaml
dse_yaml_template=/u01/datastax/dse/templates/dse.yaml
logs_dir=/u01/datastax/dse/logs
do_drain=1
start_services=1
update_system=1
install_type=advanced
system_install=services_and_utilities
enable_analytics=0
analytics_type=spark_only
enable_search=0
enable_graph=0
enable_advrepl=0
run_pfc=1
pfc_fix_issues=1
pfc_ssd=/u01/datastax/dse/data
pfc_devices=
pfc_disk_duration=60
pfc_disk_threads=10
cassandra_user=cassandra
cassandra_group=cassandra
cassandra_commitlog_dir=/u01/datastax/dse/commitlog
cassandra_data_dir=/u01/datastax/dse/data
cassandra_hints_dir=/u01/datastax/dse/hints
cassandra_saved_caches_dir=/u01/datastax/dse/saved_caches
enable_vnodes=1
listen_address=
ring_name=${ringName}
seeds=${cassandraSeeds}
EOF_PROPERTIES

    mkdir -p /u01/datastax/dse/install /u01/datastax/dse/templates /u01/datastax/dse/logs /u01/datastax/dse/data /u01/datastax/dse/commitlog /u01/datastax/dse/hints /u01/datastax/dse/saved_caches
    cp ${cassandraMediaLocation}/${cassandraMedia} /u01/datastax/dse/install
    mv /tmp/dseinstall.properties /u01/datastax/dse/install
    chmod 755 /u01/datastax/dse/install/*run
    cd /u01/datastax/dse/install
    ./${cassandraMedia} --optionfile /u01/datastax/dse/install/dseinstall.properties --mode unattended 2>&1 |tee $l_log
    
    let cnt=1
    while [ $cnt -le 10 ]; do
        STR="sleep $cnt of 10 ... wait for DSE startup"
        echo $STR
        log $STR
        sleep 30
        let DONE=`grep "DSE startup complete" /u01/datastax/dse/logs/cassandra/system.log | wc -l 2>&1`
        if [ $DONE -gt 0 ]; then
            break;
        fi
        let cnt=$cnt+1
    done       
    if [ $cnt -gt 10 ]; then
        fatalError "Exiting... DSE startup still pending after 300 seconds"
    fi
}

function configureCluster() {

    local l_log=$LOG_DIR/$g_prog.install.$$.installCassandra.log

    # https://docs.datastax.com/en/latest-dse/datastax_enterprise/production/singleDCperWorkloadType.html
    # installing a single datacenter per workload type

    cat > /tmp/cassandra.yaml << EOF_CASS_YAML
cluster_name: ${clusterName}
num_tokens: 128
hinted_handoff_enabled: true
hinted_handoff_throttle_in_kb: 1024
max_hints_delivery_threads: 2
hints_directory: /u01/datastax/dse/hints
hints_flush_period_in_ms: 10000
max_hints_file_size_in_mb: 128
batchlog_replay_throttle_in_kb: 1024
authenticator: AllowAllAuthenticator
authorizer: AllowAllAuthorizer
role_manager: com.datastax.bdp.cassandra.auth.DseRoleManager
roles_validity_in_ms: 2000
permissions_validity_in_ms: 2000
partitioner: org.apache.cassandra.dht.Murmur3Partitioner
data_file_directories:
     - /u01/datastax/dse/data
commitlog_directory: /u01/datastax/dse/commitlog
disk_failure_policy: stop
commit_failure_policy: stop
key_cache_size_in_mb:
key_cache_save_period: 14400
row_cache_size_in_mb: 0
row_cache_save_period: 0
counter_cache_size_in_mb:
counter_cache_save_period: 7200
saved_caches_directory: /u01/datastax/dse/saved_caches
commitlog_sync: periodic
commitlog_sync_period_in_ms: 10000
commitlog_segment_size_in_mb: 32
seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          - seeds: "${ipPrefix}.4,${ipPrefix}.5,${ipPrefix}.6"
concurrent_reads: 32
concurrent_writes: 32
concurrent_counter_writes: 32
concurrent_materialized_view_writes: 32
memtable_allocation_type: heap_buffers
index_summary_capacity_in_mb:
index_summary_resize_interval_in_minutes: 60
trickle_fsync: true
trickle_fsync_interval_in_kb: 10240
storage_port: 7000
ssl_storage_port: 7001
listen_address:
start_native_transport: true
native_transport_port: 9042
start_rpc: true
rpc_address: $HOSTNAME
rpc_port: 9160
rpc_keepalive: true
rpc_server_type: sync
thrift_framed_transport_size_in_mb: 15
incremental_backups: false
snapshot_before_compaction: false
auto_snapshot: true
tombstone_warn_threshold: 1000
tombstone_failure_threshold: 100000
column_index_size_in_kb: 64
batch_size_warn_threshold_in_kb: 64
batch_size_fail_threshold_in_kb: 640
unlogged_batch_across_partitions_warn_threshold: 10
compaction_throughput_mb_per_sec: 16
compaction_large_partition_warning_threshold_mb: 100
sstable_preemptive_open_interval_in_mb: 50
read_request_timeout_in_ms: 5000
range_request_timeout_in_ms: 10000
write_request_timeout_in_ms: 2000
counter_write_request_timeout_in_ms: 5000
cas_contention_timeout_in_ms: 1000
truncate_request_timeout_in_ms: 60000
request_timeout_in_ms: 10000
cross_node_timeout: false
endpoint_snitch: com.datastax.bdp.snitch.DseSimpleSnitch
dynamic_snitch_update_interval_in_ms: 100
dynamic_snitch_reset_interval_in_ms: 600000
dynamic_snitch_badness_threshold: 0.1
request_scheduler: org.apache.cassandra.scheduler.NoScheduler
server_encryption_options:
    internode_encryption: none
    keystore: resources/dse/conf/.keystore
    keystore_password: cassandra
    truststore: resources/dse/conf/.truststore
    truststore_password: cassandra
client_encryption_options:
    enabled: false
    optional: false
    keystore: resources/dse/conf/.keystore
    keystore_password: cassandra
internode_compression: dc
inter_dc_tcp_nodelay: false
tracetype_query_ttl: 86400
tracetype_repair_ttl: 604800
gc_warn_threshold_in_ms: 1000
enable_user_defined_functions: false
enable_scripted_user_defined_functions: false
windows_timer_interval: 1
EOF_CASS_YAML


    service dse stop    2>&1 |tee $l_log

    let NUM=`grep "MessagingService.java:1091 - MessagingService has terminated the accept() thread" /u01/datastax/dse/logs/cassandra/system.log | wc -l 2>&1`
    let cnt=1
    while [ $cnt -le 10 ]; do
        STR="${HOSTNAME}: sleep $cnt of 10 ... wait for DSE shutdown"
        echo $STR
        log $STR
        sleep 30
        let DONE=`grep "MessagingService.java:1091 - MessagingService has terminated the accept() thread" /u01/datastax/dse/logs/cassandra/system.log | wc -l 2>&1`
        if [ $DONE -gt $NUM ]; then
            break;
        fi
        let cnt=$cnt+1
    done       
    if [ $cnt -gt 10 ]; then
        fatalError "${HOSTNAME}: Exiting... DSE shutdown still pending after 300 seconds"
    fi
    
    rm -rf /u01/datastax/dse/data/*
    unalias cp
    cp /etc/dse/cassandra/cassandra.yaml /etc/dse/cassandra/cassandra.yaml.old
    cp -f /tmp/cassandra.yaml /etc/dse/cassandra/cassandra.yaml
    service dse start    2>&1 |tee -a $l_log

    let NUM=`grep "DSE startup complete" /u01/datastax/dse/logs/cassandra/system.log | wc -l 2>&1`
    let cnt=1
    while [ $cnt -le 10 ]; do
        STR="${HOSTNAME}: sleep $cnt of 10 ... wait for DSE startup"
        echo $STR
        log $STR
        sleep 30
        let DONE=`grep "DSE startup complete" /u01/datastax/dse/logs/cassandra/system.log | wc -l 2>&1`
        if [ $DONE -gt $NUM ]; then
            break;
        fi
        let cnt=$cnt+1
    done       
    if [ $cnt -gt 10 ]; then
        fatalError "${HOSTNAME}: Exiting... DSE startup still pending after 300 seconds"
    fi
 
    nodetool status    2>&1 |tee -a $l_log
}


function openFirewall() {
    firewall-cmd --zone=public --add-port=${cassandraPortRange}/tcp --permanent
    firewall-cmd --reload
    firewall-cmd --zone=public --list-all
}

function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    eval `grep u01_Disk_Size_In_GB $INI_FILE`
    eval `grep cassandraMediaLocation $INI_FILE`
    eval `grep cassandraMedia $INI_FILE`
    eval `grep cassandraPortRange $INI_FILE`
    eval `grep cassandraSeeds $INI_FILE`
    eval `grep ipPrefix $INI_FILE`
    eval `grep ringName $INI_FILE`
    eval `grep isCluster $INI_FILE`
    eval `grep clusterName $INI_FILE`

    l_str=""
    if [ -z $cassandraPortRange ]; then
        l_str+="cassandraPortRange not found in $INI_FILE; "
    fi
    l_str=""
    if [ -z $u01_Disk_Size_In_GB ]; then
        l_str+="${g_prog}(): u01_Disk_Size_In_GB not found in $INI_FILE; "
    fi
    if [ -z $cassandraMediaLocation ]; then
        l_str+="${g_prog}(): cassandraMediaLocation not found in $INI_FILE; "
    fi
    if [ -z $cassandraMedia ]; then
        l_str+="${g_prog}(): cassandraMedia not found in $INI_FILE; "
    fi
    if [ -z $cassandraSeeds ]; then
        l_str+="${g_prog}(): cassandraSeeds not found in $INI_FILE; "
    fi
    if [ -z $ipPrefix ]; then
        l_str+="${g_prog}(): ipPrefix not found in $INI_FILE; "
    fi
    if [ -z $ringName ]; then
        l_str+="${g_prog}(): ringName not found in $INI_FILE; "
    fi
    if [ -z $clusterName ]; then
        l_str+="${g_prog}(): clusterName not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "$g_prog(): $l_str"
    fi
    
    # function calls
    fixSwap
    fixTime
    installRPMs
    addLimits
    openFirewall
    allocateStorage
    mountMedia
    installCassandra
    if [ "$isCluster" == "true" ]; then configureCluster; fi
}


######################################################
## Main Entry Point
######################################################

log "$g_prog starting"
log "STAGE_DIR=$STAGE_DIR"
log "LOG_DIR=$LOG_DIR"
log "INI_FILE=$INI_FILE"
log "LOG_FILE=$LOG_FILE"
echo "$g_prog starting, LOG_FILE=$LOG_FILE"

if [[ $EUID -ne 0 ]]; then
    fatalError "$THIS_SCRIPT must be run as root"
    exit 1
fi

INI_FILE_PATH=$1

if [[ -z $INI_FILE_PATH ]]; then
    fatalError "${g_prog} called with null parameter, should be the path to the driving ini_file"
fi

if [[ ! -f $INI_FILE_PATH ]]; then
    fatalError "${g_prog} ini_file cannot be found"
fi

if ! mkdir -p $LOG_DIR; then
    fatalError "${g_prog} cant make $LOG_DIR"
fi

chmod 777 $LOG_DIR

cp $INI_FILE_PATH $INI_FILE

run

log "$g_prog ended cleanly"
exit $RETVAL

