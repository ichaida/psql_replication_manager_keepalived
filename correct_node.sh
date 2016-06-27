#!/usr/bin/env bash

PSQL_IP=''
PSQL_REMOTEIP=''

. common_functions.sh || exit 1

if check_state_keepalived "MASTER"; then
    psql_restart_if_necessary;
	check_psql_local_master;
    # Check the return value of the previous function 0= master, 1= not master
    if [[ $? == '0' ]]; then
		log "Node already Master DB"
		# make sure active flag is set, in order for other standbys to register & follow
        repmgr_activate_master_node || log "Fail Master node activation"
    else
		log "Promoting to master..."
		transit_to_master;
    fi
	exit 0
fi

if check_state_keepalived "BACKUP"; then
	# check if the node is invisible to repmgr ; 0 is invisible
	ping -q -c1 -W1 "${PSQL_REMOTEIP}" > /dev/null 2>&1 || exit_err "Remote node is unreachable ; nothing can be done, exiting..." 0
	_is_local_node_invisible=1
	repmgr_is_node_invisible "${PSQL_IP}" && _is_local_node_invisible=0

	if [[ ${_is_local_node_invisible} == "0" ]] ; then
        if [[ psql_xlog_recptr == -1 ]] ; then
            log "BACKUP is corrupted!"
        fi
		log "Node is BACKUP but no longer following/visible. Registering DB as standby..."
        register_node_as_standby "${PSQL_REMOTEIP}"
		exit 0
    fi

	check_psql_local_slave;
	# Check the return value of the previous function
	if [[ $? == '0' ]]; then
		log "Node already Standby all fine"
	else
		log "Node not yet Standby. Moving to slave"
		transit_to_slave "${PSQL_REMOTEIP}"
	fi
	exit 0
fi


if check_state_keepalived "FAULT" ; then
	log "Node in FAULT state ; restarting postgres..."
	psql_restart_if_necessary
fi

exit 0
