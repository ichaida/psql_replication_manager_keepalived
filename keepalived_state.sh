#!/bin/bash

. /etc/keepalived/common_functions.sh || exit 1

check_write_state_keepalived "${1}"

# Stop PostgreSQL
psql_stop

exit 0
