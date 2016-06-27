#!/usr/bin/env bash

GATEWAY_IP=""

# Check if network is reachable, return 1 if not.
# Used by keepalived to initiate a failover in case this machine is down

# PING Options are like follows
# Sending one packet c1
# In quiet mode q
# Waiting for one second W1

. common_functions.sh || exit 1

# To Check gateway reachability commandline:
# log "Gateway to be checked..."
# gateway_ip=`ip route ls | grep default | sed -e 's/^[[:space:]]*//' | awk '{ print $3 }'`
# log "Gateway IP: ${gateway_ip}"

# log "Checking network reachability..."
ping -q -c1 -W1 "${GATEWAY_IP}" > /dev/null 2>&1 || exit_err "Error pinging gateway" 1
# log "Gateway pinged successfully."

exit 0
