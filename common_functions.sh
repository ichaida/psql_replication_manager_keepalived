#!/usr/bin/env bash

# Default log path
LOG='/var/log/keepalived/psql_vrrp.log'

log() {
    _msg="${1:-Unknown}"
    _name=`basename ${0}`
    echo -e [`date +"%F %T"`] ["${_name%.*}"] "${_msg}" | tee -a "${LOG}"
}

exit_err() {
    log "${1:-Unknown}"
    exit ${2:-1}
}

# Take one argument in MASTER or SLAVE
check_write_state_keepalived() {
	_state="${1}"
	if ! grep -Fxq "${_state}" /var/run/keepalived.state; then
            echo "${_state}" > /var/run/keepalived.state
            log "Node entering \"${_state}\" state VRRP (Keepalived)"
	fi
}

check_state_keepalived() {
   _state="${1}"
   if grep -Fxq "${_state}" /var/run/keepalived.state
   then
        return 0
   fi
        return 1
}

# check if process with pid from file $1 exists
check_pid_file() {
	local _p="$1"
	[[ -z "${_p}" ]] && return 1
	[[ -f "${_p}" ]] || return 1
	kill -0 `head -n 1 "${_p}"` > /dev/null 2>&1
	return $?
}

# check if process with name $1 exists
check_process() {
	local _p="${1}"
	[[ -z "${_p}" ]] && return 1
	# this is cheaper than pidof and ps
	killall -0 "${_p}" > /dev/null 2>&1
	return $?
}

# return 0 if $1 is a valid listened port
check_listen_port() {
	local _p="$1"
	[[ -z "${_p}" ]] && return 1
	local _res=`netstat -nalp | grep "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:${_p} "`
	[[ $? -le 0 ]] && [[ -n "${_res}" ]] && return 0
	return 1
}

# check PostgreSQL connection and sample query
check_psql_connect() {
	local _res=`su - postgres -c "psql -U postgres -d postgres -q -t -c 'select 1;' | head -n 1 | tr -d ' '"`
	[[ $? -le 0 ]] && [[ "${_res}" = "1" ]] && return 0
	return 1
}

# returns 0 if master, otherwise 1
check_psql_master() {
	local _res=`su - postgres -c "psql -U postgres -h \"${1:-localhost}\" -d postgres -q -t -c 'select pg_is_in_recovery();' | head -n 1 | tr -d ' '"`
	[[ $? -le 0 ]] && [[ "${_res}" = "f" ]] && return 0
	return 1
}

# returns 0 if local master, otherwise 1 (we remove the h flag to ensure local verification)
check_psql_local_master() {
	local _res=`su - postgres -c "psql -U postgres -d postgres -q -t -c 'select pg_is_in_recovery();' | head -n 1 | tr -d ' '"`
	[[ $? -le 0 ]] && [[ "${_res}" = "f" ]] && return 0
	return 1
}

check_psql_both_node_master() {
	_PSQL_REMOTEIP="${1}"
        check_psql_local_master && check_psql_master ${_PSQL_REMOTEIP} && return 0
        return 1
}

# returns 0 if local slave, otherwise 1
check_psql_local_slave() {
	local _res=`su - postgres -c "psql -U postgres -d postgres -q -t -c 'select pg_is_in_recovery();' | head -n 1 | tr -d ' '"`
	[[ $? -le 0 ]] && [[ "${_res}" = "t" ]] && return 0
	return 1
}


check_psql_is_running() {
	local _res=`su - postgres -c "psql -U postgres -d postgres -q -t -c 'select 1;' | head -n 1 | tr -d ' '"`
	[[ $? -le 0 ]] && [[ "${_res}" == "1" ]] && return 0
	return 1
}


psql_restart() {
	/etc/init.d/postgresql restart
	[[ $? -le 0 ]] && return 0
        return 1
}

# Restart PostgreSQL if necessary
psql_restart_if_necessary() {
	# su - postgres -c "/usr/lib/postgresql/9.5/bin/pg_ctl -D /var/lib/postgresql/9.5/main restart -s"
	# If postgres is dead, restart it
	check_psql_is_running
	[[ $? -ne 0 ]] && psql_restart && return 0
	return 1
}

psql_stop() {
        /etc/init.d/postgresql stop
	[[ $? -le 0 ]] && return 0
        return 1
}

psql_stop_backup() {
	# quick fix for 'ERROR:  a backup is already in progress'
	local _res=`sudo -u postgres psql -c 'SELECT pg_xlogfile_name(pg_stop_backup());'` 
	[[ $? -le 0 ]] && return 0
	# Log if error
	log "${_res}"
        return 1
}

move_recovery_configuration() {
        [[ -f "/var/lib/postgresql/9.5/main/recovery.done" ]] && mv "/var/lib/postgresql/9.5/main/recovery.done" "/var/lib/postgresql/9.5/main/recovery.conf"
}

delete_recovery_configuration() {
        [[ -f "/var/lib/postgresql/9.5/main/recovery.conf" ]] && rm "/var/lib/postgresql/9.5/main/recovery.conf"
}

repmgr_standby_promote() {
	local _res=`su - postgres -c "/usr/bin/repmgr -f /etc/repmgr/repmgr.conf standby promote"`
	[[ $? -le 0 ]] && return 0
	log "${_res}"
        return 1
}

repmgr_standby_clone() {
	_PSQL_IP="${1}"
	local _res=`su - postgres -c "repmgr -h \"${_PSQL_IP}\" -U repmgr -d repmgr -D /var/lib/postgresql/9.5/main -f /etc/repmgr/repmgr.conf --wait --rsync-only --verbose --ignore-external-config-files --force standby clone"`
	[[ $? -le 0 ]] && return 0
	log "${_res}"
        return 1
}

repmgr_standby_register() {
	local _res=`su - postgres -c "repmgr -f /etc/repmgr/repmgr.conf standby register --force"`
	[[ $? -le 0 ]] && return 0
        log "${_res}"
	return 1
}

repmgr_repl_table_info() {
	_PSQL_IP="${1}"
	local _res_host=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT id, conninfo, type, upstream_node_id FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE cluster = '${CLUSTER_NAME}';\" " | grep "${_PSQL_IP}"` 
	local _upstream_node=`echo ${_res_host} | awk 'BEGIN { FS="|" } { print $4 }' | sed -e 's/^[[:space:]]*//'`
	local _type=`echo ${_res_host} | awk 'BEGIN { FS="|" } { print $3 }' | sed -e 's/^[[:space:]]*//'`
	local _id=`echo ${_res_host} | awk 'BEGIN { FS="|" } { print $1 }' | sed -e 's/^[[:space:]]*//'`
	
	log "${_PSQL_IP}: Upstream=${_upstream_node} Type=${_type} Id=${_id}"
	
	
	local _res_upstream_standby=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT id, active, upstream_node_id, type, conninfo FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE id = \"${_id}\";\""`
	if [[ $? -le 0 ]] && [[ ! -z ${_res_upstream_standby} ]]; then
		local _is_active=`echo ${_res_upstream_standby} | awk 'BEGIN { FS="|" } { print $2 }' | sed -e 's/^[[:space:]]*//'`
	[[ $? -le 0 ]] && [[ ${_is_active} == 't' ]] && log "${_PSQL_IP}: is Active "
	
	fi
}

# Return the id of an active master, -1 otherwise
repmgr_master_node_id() {
	local _res_master_id=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT id FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE cluster = '${CLUSTER_NAME}' AND type = 'master' ;\"" | sed -e 's/^[[:space:]]*//'`
	if [[ $? -le 0 ]] && [[ ! -z ${_res_master_id} ]]; then
		return "${_res_master_id}" 
	fi
	return -1
}

repmgr_active_master_node_id() {
        local _res_master_id=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT id FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE cluster = '${CLUSTER_NAME}' AND type = 'master' AND active IS TRUE ;\"" | sed -e 's/^[[:space:]]*//'`
        if [[ $? -le 0 ]] && [[ ! -z ${_res_master_id} ]]; then
                return "${_res_master_id}"
        fi
        return -1
}

repmgr_activate_master_node() {
        su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"UPDATE repmgr_${CLUSTER_NAME}.repl_nodes SET active = TRUE WHERE cluster = '${CLUSTER_NAME}' AND type = 'master' ;\""
        [[ $? -le 0 ]] && return 0
        return 1
}

repmgr_node_id() {
    _NODE_PATTERN="${1}"
    local _res_id=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT id, name, conninfo  FROM repmgr_dalkia_${CLUSTER_NAME}_nodes WHERE cluster = '${CLUSTER_NAME}' ;\"" | grep -E "${_NODE_PATTERN}" | head -n 1 | awk -F'|' '{ print $1 }' | sed -e 's/^[[:space:]]*//'`
    if [[ $? -le 0 ]] && [[ ! -z ${_res_id} ]]; then
        return "${_res_id}"
    fi
    return -1
}

repmgr_master_conn_info() {
	# Retreive connection information of an active master
	local _res=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"SELECT conninfo FROM repmgr_${CLUSTER_NAME}.repl_nodes WHERE cluster = '${CLUSTER_NAME}' and type = 'master' AND active IS TRUE ;\"" | sed -e 's/^[[:space:]]*//'`
}

psql_xlog_recptr() {
	local _res=`su - postgres -c 'psql -q -t -c "SELECT pg_last_xlog_receive_location() ;"' | sed -e 's/^[[:space:]]*//'`
	if [[ $? -le 0 ]]; then
 		[[ ${_res} == 'O/O' ]] && log "Node has a problem (Replication database is corrupted)" && return -1
		return 0
	fi
    log "pg_last_xlog_receive_location ${_res}"
	return 1
}

# return 0 if node is invisible, 1 otherwize
repmgr_is_node_invisible() {
    _NODE_PATTERN="${1}"
    local _res=`psql -U repmgr -d repmgr -q -t -c "SELECT conninfo FROM repmgr_${CLUSTER_NAME}.repl_nodes;" | grep -E "${_NODE_PATTERN}" | sed -e 's/^[[:space:]]*//'`
    if [[ $? -le 0 ]] && [[ ! -z ${_res} ]]; then
        return 1
    fi
    return 0
}

repmgr_update_upstream_id() {
    local _master_id="${1}"
    local _current_node_id="${2}"
    local _res=`su - postgres -c "psql -U repmgr -d repmgr -q -t -c \"UPDATE repmgr_${CLUSTER_NAME}.repl_nodes SET upstream_node_id = \"${_master_id}\", active = TRUE WHERE id = \"${_current_node_id}\";\" " | sed -e 's/^[[:space:]]*//'`
    [[ $? -le 0 ]] && return 0
    return 1
}

transit_to_master() {
   log "Initiating PostgreSQL Master transition...";
   # If it's not already Master VRRP
   check_write_state_keepalived "MASTER";
   # Deleting reconvery configuration file release the node from slave mode
   # delete_recovery_configuration
   # Restart PostgreSQL command
   psql_restart_if_necessary || log "Unable to restart PostgreSQL";

   # Cluster must contain only one active master
   # repmgr_master_node_id;

   # Check if DB Master in local machine
   check_psql_local_master;
   if [[ $? == '0' ]]; then
	  log "Node already database Master, nothing todo.";
	  log "Quiting PostgreSQL Master transition.";
	  return 0
   else
      log "Node not yet database Master, Promoting to master...";
      # let 3s for peer DB to stop
      sleep 3;
      repmgr_standby_promote || exit_err "Failed promoting to database Master" 1
   fi
   log "Done PostgreSQL Master transition with success."
   return 0
}

register_node_as_standby() {
    PSQL_REMOTEIP="${1}"
    # Stopping PostgreSQl instance
    psql_stop && log "PostgreSQL stopped sucessfully";
    log "Current node not yet standby, sleep 15 second, cloning database from remote master...";
    sleep 15;
    # Clone the database
    repmgr_standby_clone "${PSQL_REMOTEIP}" || exit_err "Failed to clone remote master, exiting..." 1
    log "Restarting PostgreSQL server...";
    # Restart postgresql
    psql_restart || log "PostgreSQL unable to stop";
    log "Registering node as standby...";
    # Register node as standby
    repmgr_standby_register || exit_err "Failed to register node as standby..." 1
    log "Done registering node as standby with success";
}

transit_to_slave() {
    PSQL_REMOTEIP="${1}"
    # If it's already BACKUP VRRP
    check_write_state_keepalived "BACKUP";
    delete_recovery_configuration
    # Restart PostgreSQL if necessary
    psql_restart_if_necessary || log "Unable de restart PostgreSQL";
    # Check if DB Slave in local machine  
    check_psql_local_slave;
    # Check the return value of the previous function
    if [[ $? == '0' ]]; then
   	   log "Node already standby, exiting...";
       return 0;
    else
	   register_node_as_standby "${PSQL_REMOTEIP}"
    fi
    return 0
}
