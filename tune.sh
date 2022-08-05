#!/bin/bash
# base on pgtune, DB type usage limit OLTP for used at netzme

__pgVersion=$1
__diskType=$2
__max_connections=$3
__max_ram_used=$4

case $1 in
       --help|-h)
       echo "usage $0 <pg_version(96|10|11)> <disk_type(hdd|ssd)> <max_connection> <max_ram_used[MB]>"
       exit 1
        ;;
esac

[ -z $__pgVersion ] && __pgVersion=11
[ -z $__diskType ] && __diskType=hdd
[ -z $__max_connections ] && __max_connections=200
if [ -z $__max_ram_used ]; then
__totalMemory=$(cat /proc/meminfo|grep MemTotal:|awk '{print $2}')
else
__totalMemory=$(expr $__max_ram_used \* 1024)
fi

if [[ $__pgVersion -ne 96 && $__pgVersion -ne 10 && $__pgVersion -ne 11 ]]; then
    echo "usage $0 <pg_version(96|10|11)> <disk_type(hdd|ssd)> <max_connection>"
    exit 1
fi

defaultData () {
    __listen_addresses="*"
    __archive_mode=on
    __archive_command="/bin/true"
    __max_replication_slots=10
    __wal_level=replica
    __max_wal_senders=3
    __wal_keep_segments=1000
    __hot_standby=on
    __log_checkpoints=on
    __synchronous_commit=local
    __wall_compression=on
    __checkpoint_completion_target=0.9
    __autovacuum_vacuum_scale_factor=0.4
    if [ "$__diskType" == "ssd" ]; then
        __effective_io_concurrency=200
        __random_page_cost=1.1
    else
        __effective_io_concurrency=2
        __random_page_cost=4.0
    fi
}
defaultData
## gunakan value memory yang sudah di round down agar tidak full pakai semua memory
if [ $__totalMemory -lt 1048576 ]; then
    __useable_memory=$(expr $__totalMemory / 1024)
    __useable_memory=$(expr $__useable_memory \* 1024)
else
    __useable_memory=$(expr $__totalMemory / 1048576)
    __useable_memory=$(expr $__useable_memory \* 1048576)
fi

__numberCpuThread=$(grep -c ^processor /proc/cpuinfo)
if [ $__numberCpuThread -eq 1 ]; then
    __max_worker_process=1
    __max_parallel_workers_per_gather=1
    __max_parallel_workers=1
else
    __max_worker_process=$__numberCpuThread
    __max_parallel_workers_per_gather=$(expr $__numberCpuThread / 2 )
    __max_parallel_maintenance_workers=$(expr $__numberCpuThread / 2 )
    __max_parallel_workers=$__numberCpuThread
fi
__effective_cache_size=$(expr $__useable_memory \* 3 / 4)
__maintenance_work_mem=$(expr $__useable_memory / 16)
__shared_buffers=$(expr $__useable_memory / 4)
__wal_buffers=$(expr 3 \* $__shared_buffers / 100)
__max_wal_buffer=$(expr 16 \* 1048576 / 1024)
__wal_buffer_near=$(expr 14 \* 1048576 / 1024)
if [ $__wal_buffers -gt $__max_wal_buffer ]; then
    __wal_buffers=$__max_wal_buffer
fi
if [[ $__max_wal_buffer -gt $__wal_buffer_near &&  $__wal_buffers -lt $__max_wal_buffer ]]; then
    __wal_buffers=$__max_wal_buffer
fi
if [ $__wal_buffers -lt 32 ]; then
    __wal_buffers=32
fi
# Cap maintenance RAM at 2GB on servers with lots of memory
if [ $__maintenance_work_mem -gt 2097152 ]; then
    __maintenance_work_mem=2097152
fi
# calculate work_mem
__work_mem_max_conection_calc=$(expr $__max_connections \* 3)
__work_memA=$(expr $__useable_memory - $__shared_buffers)
__work_memB=$(expr $__work_memA / $__work_mem_max_conection_calc )
__work_mem=$(expr $__work_memB / $__max_parallel_workers_per_gather )
if [ $__work_mem -lt 64 ]; then
    __work_mem=64
fi

printf "### ADD BY NETZME-SRE, PGTUNE WITH OLTP SCHEMA
listen_addresses = '$__listen_addresses'
max_connections = $__max_connections
superuser_reserved_connections = 3\n"
if [ $__numberCpuThread -gt 1 ]; then
    printf "max_worker_processes = $__max_worker_process\nmax_parallel_workers_per_gather = $__max_parallel_workers_per_gather\n"
fi
if [[ $__pgVersion -ne 96 && $__numberCpuThread -gt 1 ]]; then
   printf "max_parallel_workers = $__max_parallel_workers\nmax_parallel_maintenance_workers = $__max_parallel_maintenance_workers\n"
fi
printf "effective_cache_size = ${__effective_cache_size}kB
work_mem = ${__work_mem}kB
maintenance_work_mem = ${__maintenance_work_mem}kB
shared_buffers = ${__shared_buffers}kB
archive_mode = on
archive_command = '/bin/true'
max_replication_slots = 10
wal_buffers = ${__wal_buffers}kB
min_wal_size = 2GB
max_wal_size = 4GB
wal_level = replica
max_wal_senders = 3
wal_keep_segments = 1000
wal_compression = on
hot_standby = on
log_checkpoints = on
synchronous_commit = local
checkpoint_completion_target = 0.9
autovacuum_vacuum_scale_factor = 0.4
effective_io_concurrency = $__effective_io_concurrency
random_page_cost = $__random_page_cost
default_statistics_target = 100\n"
