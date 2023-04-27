#!/bin/bash

# check existence of file
if [[ ! -f $1 ]]; then
    echo "$1: File does not exist"
    exit 1
fi

export host=`hostname -s`
export today=`date +%Y%m%d`

export log_file=
export curnode_idx=
export conf_file=$1
export full_path=`readlink -f $conf_file`
export script_dir="`dirname $full_path`/log"

mkdir -p ${script_dir}

################################################################################
# Log module
################################################################################yy
function _log_print() {
    level=$1
    message=$2
    today=`date +%Y%m%d`
    log_file="${script_dir}/ha.${dbtype}.${host}.${today}.log"
    t=`date '+%Y-%m-%d %H:%M:%S'`
    printf '%s-%s-%s-%s\n' "$t" "$level" "${BASH_LINENO[1]}" "$message" | tee -a ${log_file}
}
export -f _log_print

function log_info() {
    _log_print "INFO" "$1"
}
export -f log_info

function log_warn() {
    _log_print "WARN" "$1"
}
export -f log_warn

function log_error() {
    _log_print "ERROR" "$1"
}
export -f log_error

function log_fatal() {
    _log_print "FATAL" "$1"
}
export -f log_fatal

function log_panic() {
    _log_print "PANIC" "$1"
    exit 1
}
export -f log_panic
################################################################################

function _jq() {
    ret=`cat ${conf_file} | jq -r ${1}`
    if [[ $ret == 'null' ]]; then
        ret=''
    fi
    echo $ret
}
export -f _jq

######################
# db section
export dbtype=`_jq '.db.type'`     # db type
export db_uid=`_jq '.db.userid'`   # userid of admin
export pwd=`_jq '.db.passwd'`      # password of admin
# os section
export os_uid=`_jq '.os.userid'`   # os user id
######################
# promote section
export script_pre_promotion=`_jq '.promote.script_pre'`    # script to run before promotion
export script_post_promotion=`_jq '.promote.script_post'`  # script to run after promotion
export promote_timeout=`_jq '.promote.timeout'`        # timeout for promotion
export max_retry_cnt=`_jq '.promote.max_retry_count'`  # max retry count for promotion
export check_interval=`_jq '.promote.check_interval'`  # interval to check promotion status
export dns_api_server=`_jq '.promote.dns_api_server'`  # dns server to update
export dns_timeout=`_jq '.promote.dns_timeout'`        # dns timeout (unit: sec) (for curl --max-time)
if [[ $dns_timeout == "" ]]; then
    export dns_timeout=60 # default: 60
fi
######################
# coordinators section
export curnode_idx=`_jq '.current_node_index'`         # index of current node
# role_of_this_node=`_jq '.role_of_this_node'`    # role of this node
# declare structure coordinators as an array of objects with name, role, addr and port
declare -A coordinator0=(
    [idx]="0"
    [name]=`_jq '.coordinators[0].name'`
    [role]=`_jq '.coordinators[0].role'`
    [addr]=`_jq '.coordinators[0].addr'`
    [ip]=`_jq '.coordinators[0].ip'`
    [port]=`_jq '.coordinators[0].port'`
)

declare -A coordinator1=(
    [idx]="1"
    [name]=`_jq '.coordinators[1].name'`
    [role]=`_jq '.coordinators[1].role'`
    [addr]=`_jq '.coordinators[1].addr'`
    [ip]=`_jq '.coordinators[1].ip'`
    [port]=`_jq '.coordinators[1].port'`
)

declare -A coordinator2=(
    [idx]="2"
    [name]=`_jq '.coordinators[2].name'`
    [role]=`_jq '.coordinators[2].role'`
    [addr]=`_jq '.coordinators[2].addr'`
    [ip]=`_jq '.coordinators[2].ip'`
    [port]=`_jq '.coordinators[2].port'`
)

# export variables for coordinators
export coordinator0
export coordinator1
export coordinator2

declare -n coord_cur
declare -n coord_master
declare -n coord_standby
declare -n coord_monitor
# export coord_cur
# export coord_master
# export coord_standby
# export coord_monitor

function init_coordinators() {
    # set current coordinator with curnode_idx
    _tmp="coordinator${curnode_idx}"
    coord_cur="${_tmp}"

    # set current coordinator with curnode_idx
    declare -n c # reference to coordinator
    for c in ${!coordinator@}; do
        # set master/standby/monitor coordinator
        role="${c[role]}"

        # if [[ "$role_of_this_node" == "$role" ]]; then
        #     _tmp="coordinator${c[idx]}"
        #     coord_cur="${_tmp}"
        # fi

        case $role in
            'master')
                _tmp="coordinator${c[idx]}"
                coord_master="${_tmp}"
                ;;
            'standby')
                _tmp="coordinator${c[idx]}"
                coord_standby="${_tmp}"
                ;;
            'monitor')
                _tmp="coordinator${c[idx]}"
                coord_monitor="${_tmp}"
                ;;
            *)
                log_panic "Unknown role: $role"
                ;;
        esac
    done

    case $dbtype in
        'singlestore' | 'greenplum')
            # pass!
            ;;
        *)
            log_panic "Unknown dbtype: $dbtype"
            ;;
    esac
}
export -f init_coordinators
