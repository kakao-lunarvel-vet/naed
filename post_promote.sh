#!/usr/bin/env bash

if [[ $# != 1 ]]; then
    echo "Usage: $0 <config file>"
    exit 1
fi

# init & import variables
. _init_.sh $1


# check variables: dns_api_server, coordip_master, coordip_standby(current nodes)
if [[ -z "$dns_api_server" ]]; then
    log_error "dns_api_server is not set"
    exit 1
fi

if [[ -z "${coord_master[addr]}" ]]; then
    log_error "coord_master[addr] is not set"
    exit 1
fi

if [[ -z "${coord_cur[ip]}" ]]; then
    log_error "coord_standby[ip] is not set"
    exit 1
fi

# FQDN 변경
# check current node is standby (imply that this node was promoted and now is master)
if [[ "${coord_cur[role]}" == "standby" ]]; then

    cmdline="curl --max-time ${dns_timeout} -v http://${dns_api_server}/api/${coord_master[addr]}?value=${coord_cur[ip]} -XPUT"

    # promote this node to master
    log_warn "standby: change to the FQDN binded at master. ($cmdline)"
    res=$(eval $cmdline)

    # 200: 성공
    echo "$res" | grep -q "HTTP/1.1 200 OK"
    if [[ "$?" == "0" ]]; then
        log_warn "SUCCESS to change FQDN."
        exit 0
    fi

    # 400: 도메인 형식이나 ip형식이 맞지 않는 경우
    echo "$res" | grep -q "HTTP/1.1 400 Bad Request"
    if [[ "$?" == "0" ]]; then
       log_error "FAIL to change FQDN: check DNS or IP"
       exit 1
    fi

    # 403: 이 zone에 대해서 허락되지 않은 ip에서 요청이 들어온 경우
    echo "$res" | grep -q "HTTP/1.1 403 Forbidden"
    if [[ "$?" == "0" ]]; then
       log_error "FAIL to change FQDN: this host(${coord_cur[addr]}:${coord_cur[addr]} is not allowed to update DNS"
       exit 1
    fi

    # 404: api사용에 열려있지 않은 zone에 대해 등록한 경우
    echo "$res" | grep -q "HTTP/1.1 404 Not Found"
    if [[ "$?" == "0" ]]; then
       log_error "FAIL to change FQDN: check DNS zone"
       exit 1
    fi

    # 500: (한 서버라도) nsupdate가 실패한 경우
    echo "$res" | grep -q "HTTP/1.1 500 Internal Server Error"
    if [[ "$?" == "0" ]]; then
       log_error "FAIL to change FQDN: check DNS server"
       exit 1
    fi
fi
