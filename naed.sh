#!/usr/bin/env bash


# check args # is 2
if [[ $# != 1 ]]; then
    echo "Usage: $0 <config file>"
    exit 1
fi

# check existence of file
if [[ ! -f $1 ]]; then
    echo "$1: File does not exist"
    exit 1
fi

# check arg 2 is a number
# if [[ ! $2 =~ ^[0-9]+$ ]]; then
#     echo "Arg 2 is not a number"
#     exit
# fi

log_file=
full_path=`readlink -f $0`
script_dir="`dirname $full_path`/log"
mkdir -p ${script_dir}
today=`date +%Y%m%d`

host=`hostname -s`
conf_file=$1
curnode_idx=
role_of_this_node=

function _jq() {
    ret=`cat ${conf_file} | jq -r ${1}`
    if [[ $ret == 'null' ]]; then
        ret=''
    fi
    echo $ret
}

# dbtype=`cat $conf_file |  jq -r '.dbtype'`
dbtype=`_jq '.db.type'` # db type
db_uid=`_jq '.db.userid'` # userid of admin
pwd=`_jq '.db.passwd'` # password of admin
os_uid=`_jq '.osuid'` # os user id
script_pre_promotion=`_jq '.promote.script_pre'` # script to run before promotion
script_post_promotion=`_jq '.promote.script_post'` # script to run after promotion
promote_timeout=`_jq '.promote.timeout'` # timeout for promotion
max_retry_cnt=`_jq '.promote.max_retry_count'` # max retry count for promotion
check_interval=`_jq '.promote.check_interval'` # interval to check promotion status
role_of_this_node=`_jq '.role_of_this_node'` # role of this node

function log_info() {
    _log_print "INFO" "$1"
}

function log_warn() {
    _log_print "WARN" "$1"
}

function log_error() {
    _log_print "ERROR" "$1"
}

function log_fatal() {
    _log_print "FATAL" "$1"
}

function log_panic() {
    _log_print "PANIC" "$1"
    exit 1
}

function _log_print() {
    level=$1
    message=$2
    today=`date +%Y%m%d`
    log_file="${script_dir}/ha.${dbtype}.${host}.${today}.log"
    t=`date '+%Y-%m-%d %H:%M:%S'`
    printf '%s-%s-%s-%s\n' "$t" "$level" "${BASH_LINENO[1]}" "$message" | tee -a ${log_file}
}

# declare structure coordinators as an array of objects with name, role, addr and port
declare -A coordinator0=(
    [idx]="0"
    [name]=`_jq '.coordinators[0].name'`
    [role]=`_jq '.coordinators[0].role'`
    [addr]=`_jq '.coordinators[0].addr'`
    [port]=`_jq '.coordinators[0].port'`
)

declare -A coordinator1=(
    [idx]="1"
    [name]=`_jq '.coordinators[1].name'`
    [role]=`_jq '.coordinators[1].role'`
    [addr]=`_jq '.coordinators[1].addr'`
    [port]=`_jq '.coordinators[1].port'`
)

declare -A coordinator2=(
    [idx]="2"
    [name]=`_jq '.coordinators[2].name'`
    [role]=`_jq '.coordinators[2].role'`
    [addr]=`_jq '.coordinators[2].addr'`
    [port]=`_jq '.coordinators[2].port'`
)

##############################################################################

declare -n coord_cur
declare -n coord_master
declare -n coord_standby
declare -n coord_monitor

function init_coordinators() {
    # set current coordinator with curnode_idx
    declare -n c # reference to coordinator
    for c in ${!coordinator@}; do
        # set master/standby/monitor coordinator
        role="${c[role]}"

        if [[ "$role_of_this_node" == "$role" ]]; then
            _tmp="coordinator${c[idx]}"
            coord_cur="${_tmp}"
        fi

        case $role in
            'master')
                _tmp="coordinator${c[idx]}"
                coord_master="${_tmp}"
                #echo "master: ${coord_master[name]} ${coord_master[addr]} ${coord_master[port]}"
                ;;
            'standby')
                _tmp="coordinator${c[idx]}"
                coord_standby="${_tmp}"
                #echo "standby: ${coord_standby[name]} ${coord_standby[addr]} ${coord_standby[port]}"
                ;;
            'monitor')
                _tmp="coordinator${c[idx]}"
                coord_monitor="${_tmp}"
                #echo "monitor: ${coord_monitor[name]} ${coord_monitor[addr]} ${coord_monitor[port]}"
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

function exec_cmd() {
    # we run shell cmd with timeout
    cmd="${1}";
    timeout="${2}";
    grep -qP '^\d+$' <<< $timeout || timeout=60
    result=$(timeout $timeout bash -c "$cmd")
    log_info="${result}"
    ret=$?
    if [[ $ret == 124 ]]; then
        log_panic "Killed $cmd because of timeout"
    fi

    return $ret
}

function _check_connection_with_client_tool() {
    dest_addr=$1
    dest_port=$2
    dest_role=$3

    # check connection with client tool
    if [[ (! -z $dest_role) && "$dest_role" == "monitor" ]]; then
        ping -c 1 -i 10 ${dest_addr} > /dev/null 2> /dev/null
        ret=$?
    else
        case $dbtype in
            'singlestore')
                memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p${pwd} <<< '' > /dev/null 2> /dev/null
                ret=$?
                ;;
            'greenplum')
                # if pwd is null, then -W will be ignored
                pwd_opt=''
                if [[ ! -z "$pwd" ]]; then
                    pwd_opt="-W ${pwd}"
                fi
                # echo "psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only <<< '' > /dev/null 2> /dev/null" >> tmp.out
                psql_result=$(psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only <<< '' 2>&1)
                ret=$?
                if [[ "$ret" != "0" ]]; then
                    echo $psql_result | grep "the database system is in recovery mode" > /dev/null
                    ret=$?
                fi
                ;;
            *)
                log_panic "Unknown dbtype: $dbtype"
                ;;
        esac
    fi
    echo $ret
}

function _check_connection_with_client_tool_2() {
    dest_addr=$1
    dest_port=$2
    dest_role=$3

    pwd_opt=''
    
    # check connection with client tool
    if [[ $dest_role == "monitor" ]]; then
        ping -c 1 -i 10 ${dest_addr} > /dev/null 2> /dev/null
        ret=$?
    else
        case $dbtype in
            'singlestore')
    echo $promote_addr > tmp.out
                echo "memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p ${pwd} <<< '' > /dev/null 2> /dev/null" > tmp.out
                memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p${pwd} <<< '' > /dev/null 2> /dev/null
                ret=$?
                ;;
            'greenplum')
                # if pwd is null, then -W will be ignored
                if [[ $dest_role == "master" ]]; then
                    if [[ ! -z "$pwd" ]]; then
                        pwd_opt="-W ${pwd}"
                    fi
                    psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only <<< '' > /dev/null 2> /dev/null
                    ret=$?
                else
                    is_run_postgres=`ps -ef | grep postgres | grep "p $dest_port" | grep -v grep | wc -l`
                    if [[ "$is_run_postgres" == "0" ]]; then
                        ret=1
                    else
                        ret=0
                    fi
                fi
                ;;
            *)
                log_panic "Unknown dbtype: $dbtype"
                ;;
        esac
    fi

    echo $ret
}


function make_cmd_line_remote() {
    sql=$1
    dest_addr=$2
    dest_port=$3

    # check connection with client tool
    if [[ "$dest_role" == "monitor" ]]; then
        ping -c 1 -i 10 ${dest_addr} > /dev/null 2> /dev/null
    else
        case $dbtype in
            'singlestore')
                printf "memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p${pwd} --skip-column-names <<< \"$sql\" 2> /dev/null\n"
                ;;
            'greenplum')
                # if pwd is null, then -W will be ignored
                pwd_opt=''
                if [[ ! -z "$pwd" ]]; then
                    pwd_opt="-W ${pwd}"
                fi
                printf "psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only -c \"$sql\"\n"
                ;;
            *)
                log_panic "Unknown dbtype: $dbtype"
                ;;
        esac
    fi
}

function make_cmd_line_local() {
    dest_addr='localhost'
    dest_port="${coord_cur[port]}"
    sql=$4

    # check connection with client tool
    if [[ "$dest_role" == "monitor" ]]; then
        ping -c 1 -i 10 ${dest_addr} > /dev/null 2> /dev/null
    else
        case $dbtype in
            'singlestore')
                printf "memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p${pwd} --skip-column-names <<< \"$sql\" 2> /dev/null\n"
                ;;
            'greenplum')
                # if pwd is null, then -W will be ignored
                pwd_opt=''
                if [[ ! -z "$pwd" ]]; then
                    pwd_opt="-W ${pwd}"
                fi
                printf "psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only -c \"$sql\"\n"
                ;;
            *)
                log_panic "Unknown dbtype: $dbtype"
                ;;
        esac
    fi
}

function check_connection_with_client_tool_at_remote() {
    cmdline=''
    src_addr=$1
    dest_addr=$2
    dest_port=$3

    # check connection with client tool
    case $dbtype in
        'singlestore')
            cmdline=`printf "memsql -h ${dest_addr} -P ${dest_port} -u ${db_uid} -p${pwd} --skip-column-names <<< \"$sql\" 2> /dev/null\n"`
            ;;
        'greenplum')
            # if pwd is null, then -W will be ignored
            pwd_opt=''
            if [[ ! -z "$pwd" ]]; then
                pwd_opt="-W ${pwd}"
            fi
            cmdline=`printf "psql postgres -h ${dest_addr} -p ${dest_port} -U ${db_uid} ${pwd_opt} --tuples-only -c \"$sql\"\n"`
            ;;
        *)
            log_panic "Unknown dbtype: $dbtype"
            ;;
    esac

    # echo "ssh -o \"StrictHostKeyChecking=no\" \"${os_uid}@${stand_addr}\" \"${cmdline}\"" > tmp.out
    ssh -o "StrictHostKeyChecking=no" "${os_uid}@${src_addr}" "${cmdline}"
    echo $?
}

#####################################################################################
#   case of connections
#                      (monitor)
#                      /        \
#                     /          \
#                  conn1        conn2
#                   /              \
#                  /                \
#            (master) --- conn3 --- (standby)
#
#####################################################################################
#
# -----------------------------------------------------------------------------------------
#  CaseID    Connection        Cluster is  Who provides service
#            is healthy        available
# -----------------------------------------------------------------------------------------
CASE0=0   #   None               X        both of the master and standby can’t provide service(write)
CASE1=1   #   con1               O        master
CASE2=2   #   con2               O        master stops, Standby is promoted
CASE3=3   #   con3               O        master
CASE4=4   #   con1,con2          O        master
CASE5=5   #   con2,con3          O        master
CASE6=6   #   con3,con1          O        master
CASE7=7   #   con1,con2,con3     O        master
CASE_NOT_EXIST=127
#####################################################################################

function check_connection_myself() {
    # check connection myself
    ret=$(_check_connection_with_client_tool_2 ${coord_cur[addr]} ${coord_cur[port]} ${coord_cur[role]})
    echo $ret
}

function check_connection_between_cur_and_master() {
    # check connection between current coordinator and master coordinator
    ret=$(_check_connection_with_client_tool ${coord_master[addr]} ${coord_master[port]})
    echo $ret
}

function check_connection_between_cur_and_standby() {
    # check connection between current coordinator and standby coordinator
    ret=$(_check_connection_with_client_tool ${coord_standby[addr]} ${coord_standby[port]})
    echo $ret
}

function check_connection_between_cur_and_monitor() {
    # check connection between current coordinator and monitor coordinator
    ret=$(_check_connection_with_client_tool ${coord_monitor[addr]} ${coord_monitor[port]} ${coord_monitor[role]})
    echo $ret
}

function check_connection_between_monitor_standby_master() {
    # check connection standby and master
    ret=$(check_connection_with_client_tool_at_remote ${coord_standby[addr]} ${coord_master[addr]} ${coord_master[port]})
    echo $ret
}

function OSB_check_master() {
    # check connection myself
    conn=$(check_connection_myself)
    if [[ $conn != 0 ]]; then
        log_fatal "Cannot find own process: ${coord_cur[addr]}:${coord_cur[port]}"
        return $CASE_NOT_EXIST
    fi

    # check connection between current coordinator and standby coordinator
    conn3=$(check_connection_between_cur_and_standby)
    if [[ $conn3 != 0 ]]; then
        log_warn "Cannot connect to standby coordinator(${coord_standby[addr]}:${coord_standby[port]})"
    fi
    
    # check connection between current coordinator and monitor coordinator
    conn1=$(check_connection_between_cur_and_monitor)
    if [[ $conn1 != 0 ]]; then
        log_warn "Cannot connect to monitor coordinator(${coord_monitor[addr]}:${coord_monitor[port]})"
    fi

    if [[ $conn3 != 0 && $conn1 != 0 ]]; then
        log_fatal "Both of the master and standby can’t provide service(write)"
    fi

    if [[ $conn3 != 0 ]]; then
        if [[ $conn1 != 0 ]]; then
            ################################################################################
            return $CASE2 # 실제로는 $CASE0 일수도 있다. 최종적으로, 두 경우 모두다 master는 자신을 read-only로 변경하여
                        # failover하는 것으로 동일하게 동작한다. 따라서 CASE0을 리턴하며,
                        # CASE 2에 대한 판단은 monitor가 하는 것이 옳으며, CASE2로 판단될 경우에 모니터는 기존 master는 아무런 조치를 취하지 못하므로로
                        # 최종적으로 안전하다는 것이 보장된다.
            ################################################################################
        else
            return $CASE1 # or $CASE4
        fi
    else
            return $CASE5 # or $CASE7
    fi
}

function OSB_check_standby() {
    # check connection myself
    conn=$(check_connection_myself)
    if [[ $conn != 0 ]]; then
        log_fatal "Cannot find own process: ${coord_cur[addr]}:${coord_cur[port]}"
        return $CASE_NOT_EXIST
    fi

    # check connection between current coordinator and master coordinator
    conn3=$(check_connection_between_cur_and_master)
    if [[ $conn3 != 0 ]]; then
        log_warn "Cannot connect to master coordinator: ${coord_master[addr]}:${coord_master[port]}"
    fi

    # check connection between current coordinator and monitor coordinator
    conn2=$(check_connection_between_cur_and_monitor)
    if [[ $conn2 != 0 ]]; then
        log_warn "Cannot connect to monitor coordinator: ${coord_monitor[addr]}:${coord_monitor[port]}"
    fi

    # although above connections are not healthy, the cluster maybe available
    if [[ $conn3 != 0 && $conn2 != 0 ]]; then
        log_warn "Both of the master and standby can’t provide service(write), but the cluster maybe available"
    fi

    if [[ $conn3 != 0 ]]; then
        if [[ $conn2 != 0 ]]; then
            return $CASE1 # 실제로는 $CASE0 일수도 있다. 결론적으로, 두 경우다 프로모션을 하지 않으므로 $CASE1로 처리
        else
            ################################################################################
            return $CASE4 # !!!중요!!!! $CASE2 일수도 있지만, CASE2의 진위에 대한 판단과 failover는 monitor가 실행한다.
            ################################################################################
        fi
    else
            return $CASE3 # CASE 6,5 or 7
    fi
}

function OSB_check_monitor() {
    # check connection myself
    # conn=$(check_connection_myself)
    # if [[ $conn != 0 ]]; then
        # log_fatal "Cannot find own process: ${coord_cur[addr]}:${coord_cur[port]}"
        # return $CASE_NOT_EXIST
    # fi

    # check connection between current coordinator and master coordinator
    conn1=$(check_connection_between_cur_and_master)
    if [[ $conn1 != 0 ]]; then
        log_warn "Cannot connect to master coordinator: ${coord_master[addr]}:${coord_master[port]}"
    fi

    # check connection between current coordinator and standby coordinator
    conn2=$(check_connection_between_cur_and_standby)
    if [[ $conn2 != 0 ]]; then
        log_warn "Cannot connect to standby coordinator: ${coord_standby[addr]}:${coord_standby[port]}"
    else
        ############################################################
        # CHECK THE SPLIT-BRAIN CASE
        ############################################################
        conn3=$(check_connection_between_monitor_standby_master)
        if [[ $conn3 != 0 ]]; then
            log_warn "Standby cannot connect to master"
        fi
    fi

    # check both connections are healthy
    if [[ $conn1 != 0 && $conn2 != 0 ]]; then
        log_fatal "Both of the master and standby can’t provide service(write)"
    fi

    if [[ $conn1 != 0 ]]; then
        if [[ $conn2 != 0 ]]; then
            return $CASE1 # 실제로는 $CASE0 일수도 있다. 결론적으로, 두 경우다 프로모션을 하지 않으므로 $CASE1로 처리
        else
            if [[ $conn3 != 0 ]]; then
                ################################################################################
                return $CASE2 # !!!중요!!!! 확실한 $CASE2 이다! 페일오버를 진행해야 한다진
                ################################################################################
            else
                return $CASE5 # do nothing
            fi
        fi
    else
            return $CASE1 # or $CASE4, $CASE7 # do nothing
    fi
}

################################################################################
# case: One standby coordinator case main function (master, standby, monitor)
################################################################################
function main_OSB_check() {
    retry_cnt=0
    ret=
    cur_coord_role="${coord_cur[role]}"

    while [[ true ]]; do
        case $cur_coord_role in
            'master')
                OSB_check_master
                ret=$?
                ;;
            'standby')
                OSB_check_standby
                ret=$?
                ;;
            'monitor')
                OSB_check_monitor
                ret=$?
                ;;
            *)
                log_panic "Unknown role: $cur_coord_role"
                ;;
        esac

        case $ret in
            $CASE0 | $CASE1 | $CASE3 | $CASE4 | $CASE5 | $CASE6 | $CASE7)
                # do not return, check again
                retry_cnt=0
                sleep $check_interval;
                ;;
            $CASE2)
                # 순단이 발생한 경우, 여러번 재시도후 판단 한다.
                ((retry_cnt++))
                if [[ $retry_cnt < $max_retry_cnt ]]; then
                    return $ret
                fi
                sleep $check_interval;
                ;;
            $CASE_NOT_EXIST)
                exit 1
                ;;
            *)
                log_fatal "Unknown case: $ret"
                ;;
        esac
    done;
}


#########################################################################################################
# functions related with failover
#########################################################################################################
function FO_kill_sessions() {
    case $dbtype in
        'greenplum')
            sql="SELECT pid FROM pg_stat_activity WHERE state = 'active' and pid != pg_backend_pid()" 
            cmdline=$(make_cmd_line_local "$sql")
            pidlist=$(eval $cmdline)
            
            for i in $pidlist
            do
                log_warn "Killing session $i"
                sql="SELECT pg_terminate_backend($i)"
                cmdline=$(make_cmd_line_local "$sql")
                pidlist=$(eval $cmdline) > /dev/null 2>&1
            done;
            ;;
        'singlestore')
            sql="SELECT id FROM INFORMATION_SCHEMA.PROCESSLIST where user != 'distributed' and id != connection_id();"
            cmdline=$(make_cmd_line_local "$sql")
            pidlist=$(eval $cmdline)

            for i in $pidlist
            do
                log_warn "Killing session $i"
                sql="kill $i"
                cmdline=$(make_cmd_line_local "$sql")
                $(eval $cmdline) > /dev/null 2>&1
            done;
            ;;
        *)
            echo "Unknown dbtype: $dbtype"
            exit 1
            ;;
    esac
}


# set & unset read only mode
# info: https://www.postgresql.org/docs/9.1/sql-set-transaction.html
#  cons: only affected to the current connection
function FO_set_read_only() {
    case $dbtype in
        'greenplum')
            sql="SELECT pg_catalog.set_config('default_transaction_read_only', 'on', false);"
            cmdline=$(make_cmd_line_local "$sql")
            $(eval $cmdline) > /dev/null 2>&1
            ;;
        'singlestore')
            sql="SET GLOBAL TRANSACTION READ ONLY;"
            cmdline=$(make_cmd_line_local "$sql")
            $(eval $cmdline) > /dev/null 2>&1
            ;;
        *)
            echo "Unknown dbtype: $dbtype"
            exit 1
            ;;
    esac
}

function FO_set_writable() {
    case $dbtype in
        'greenplum')
            sql="SELECT pg_catalog.set_config('default_transaction_read_only', 'off', false);"
            cmdline=$(make_cmd_line_local "$sql")
            $(eval $cmdline) > /dev/null 2>&1
            ;;
        'singlestore')
            sql="SET GLOBAL TRANSACTION READ WRITE;"
            cmdline=$(make_cmd_line_local "$sql")
            $(eval $cmdline) > /dev/null 2>&1
            ;;
        *)
            echo "Unknown dbtype: $dbtype"
            exit 1
            ;;
    esac
}

# todo: FO_adjust_coordinators() 함수는 아래의 내용으로 구현되어야 한다.
#  각 노드의 역할이 바뀐경우, 바뀐 역할로 새로운 감시를 수행활 수 있도록 아래의 내용을 순차적으로 수행해야 한다.
#  - standby 는
#    1) 이전 설정파일을 ...cfg.json.bak.{failover시간} 으로 백업
#    2) 새로운 설정 파일에 아래 내용을 저장
#       - 변경된 롤이 저장된 코디네이터 값들.
#       - 이전 설정 파일의 경로
#    3)  다른 두 노드에 대해 아래 내용을 실행한다.
#       1) 각 노드에 맞게 "role_of_this_node" 변경 & 저장
#       2) ssh로 이전 파일 백업. (형식은 위와 동일)
#       3) 새로운 설정파일을 각 노드에 배포
#    이렇게 하면, crontab은 자동으로 스크립트를 실행할 것이고, 새로운 롤에 맞춰서 모니터링을 수행할 것.
#    어느 정도 시간이 지난 후, 사용자가 수동으로 failback 수행한다.
function FO_adjust_coordinators() {
    # adjust coordinators
    case $1 in
        $CASE1)
            log_info "CASE1: Do nothing"
            ;;
        $CASE2)
            log_info "CASE2: Do nothing"
            ;;
        $CASE3)
            log_info "CASE3: Do nothing"
            ;;
        $CASE4)
            log_info "CASE4: Do nothing"
            ;;
        $CASE5)
            log_info "CASE5: Do nothing"
            ;;
        $CASE6)
            log_info "CASE6: Do nothing"
            ;;
        $CASE7)
            log_info "CASE7: Do nothing"
            ;;
        *)
            log_fatal "Unknown case: $1"
            ;;
    esac
}

function FO_do_failover() {
    ret=0
    case $1 in
        $CASE0 | $CASE1 | $CASE3 | $CASE4 | $CASE5 | $CASE6 | $CASE7)
            log_info "CASE${1}: Do nothing"
            ;;
        $CASE2)
            # When only current node is monitor, it makes the standby coordinator to promote
            role="${coord_cur[role]}"
            if [[ "$role" == "monitor" ]]; then
                
                # execute the script file BEFORE promotion
                if [[ ! -z "${script_pre_promotion}" && -f "${script_pre_promotion}" ]]; then
                    log_info "CASE2: Execute the script file before promotion: ${script_pre_promotion}"
                    bash ${script_pre_promotion} ${conf_file} | tee -a ${log_file}
                fi
                
                # execute promotion
                log_info "CASE2: Promote the standby coordinator"
                FO_promote_standby
                ret=$?
                
                # execute the script file AFTER promotion
                if [[ ! -z "${script_post_promotion}" && -f "${script_post_promotion}" ]]; then
                    log_info "CASE2: Execute the script file after promotion: ${script_post_promotion}"
                    bash ${script_post_promotion} ${conf_file} | tee -a ${log_file}
                fi
            else
                # master 인 경우, 기존 모든 세션 종료 & 그 와중에 monitor 에서 DNS 변경 및 보호)
                # 아니라면("standby" 인 경우), 아무것도 하지 않음
                if [[ $role == "master" ]]; then
                    log_info "CASE2: kill all sessions"
                    FO_kill_sessions
                
                else
                    log_info "CASE2: Do nothing"
                fi
            fi
            ;;
        *)
            log_fatal "Unknown case: $1"
            ;;
    esac

    return 0
}

function FO_promote_standby() {
    # promote standby coordinator
    promote_addr="${coord_standby[addr]}"
    promote_port="${coord_standby[port]}"

    case $dbtype in
        'greenplum')
            in_cmdline="gpactivatestandby -a"
            cmdline=$(printf "ssh -o 'StrictHostKeyChecking=no' %s '%s'" "${os_uid}@${promote_addr}" "${in_cmdline}")
            ;;
        'singlestore')
            sql="AGGREGATOR SET AS MASTER;"
            cmdline=$(make_cmd_line_remote "$sql" "${promote_addr}" "${promote_port}")
            ;;
        *)
            echo "Unknown dbtype: $dbtype"
            exit 1
            ;;
    esac

    exec_cmd "$cmdline" $promote_timeout
    log_warn "Complete of promotion. Check the log: ${log_file}"
    return $?
}

# check this script is running only one at once
function check_atomic_exec_with_pidfile() {
    local script_name=$(basename $0)
    local pidfile="/tmp/.${script_name}.${dbtype}.pid"
    local pid

    if [[ -f $pidfile ]]; then
        pid=$(cat $pidfile)
        if [[ -d /proc/$pid ]]; then
            grep --text ${script_name} /proc/${pid}/cmdline > /dev/null
            if [[ $? == 0 ]]; then
                # "Another instance of this script is running with pid $pid"
                exit 0
            fi
        else
            log_warn "Removing stale pidfile $pidfile"
            rm -f $pidfile
        fi
    fi

    echo $$ > $pidfile
}

function remove_pidfile() {
    local script_name=$(basename $0)
    local pidfile="/tmp/.${script_name}.${dbtype}.pid"
    local pid

    if [[ -f $pidfile ]]; then
        pid=$(cat $pidfile)
        if [[ -d /proc/$pid ]]; then
            grep --text ${script_name} /proc/${pid}/cmdline > /dev/null
            if [[ $? == 0 ]]; then
                rm -f $pidfile
            fi
        fi
    fi
}


################################################################################
# main 함수
#  monitor가 실행되는 노드가 empty인지 아닌지에 따라 다르게 동작한다.
################################################################################
function main() {
    log_info "start the auto failover script"
    
    log_info "conf file: ${conf_file}"
    conf_file_content=`cat ${conf_file} | jq -r`
    log_info "${conf_file_content}"

    # check this script is running only one at once
    check_atomic_exec_with_pidfile

    # init coordinators
    init_coordinators

    # check network connection between coordinators
    log_info "check coordinators network connection repeatedly"
    main_OSB_check
    ret=$?

    # check ret value, then do failover
    FO_do_failover $ret

    # remove the pidfile
    remove_pidfile
}
################################################################################
# call main
main
################################################################################

# echo "current: ${coord_cur[name]} ${coord_cur[addr]} ${coord_cur[port]}"
# echo "master : ${coord_master[name]} ${coord_master[addr]} ${coord_master[port]}"
# echo "standby: ${coord_standby[name]} ${coord_standby[addr]} ${coord_standby[port]}"
# echo "monitor: ${coord_monitor[name]} ${coord_monitor[addr]} ${coord_monitor[port]}"
