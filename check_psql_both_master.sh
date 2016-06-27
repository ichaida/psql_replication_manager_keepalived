#!/usr/bin/env bash

PSQL_REMOTEIP=''

# We import the shared code functions
. common_functions.sh || exit 1

check_psql_both_node_master "${PSQL_REMOTEIP}"
if [ $? -le 0 ]
then
    log "Both nodes are database Master"
    if check_state_keepalived "MASTER"
    then
        log "VRRP state is MASTER - Do nothing";
        # Stopping eventual PostgreSQL backup on the master that the opposite node can proceed with new one
        # psql_stop_backup || log "PostgreSQL failed to stop backup";
    else
        log "VRRP state is Backup - Forcing current node to demote from Master, registering as standby...";
        register_node_as_standby "${PSQL_REMOTEIP}"
        # Exiting with 1 allow the current node to lose keepalived's priority points 
        exit 1
   fi
fi

exit 0
