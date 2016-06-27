#!/usr/bin/env bash

# Fix does only work when running with pg_ctl
# PSQL_PID_FILE='/var/lib/postgresql/9.5/main/postmaster.pid'


. common_functions.sh || exit 1

#PSQL_PORT='5432'
#check_listen_port "${PSQL_PORT}" || exit_err 'Listen Port' 1

#check_psql_connect || exit_err 'PSQL Connect: Connect failure' 1

check_process "postgres" || exit_err 'PSQL process not running' 1

exit 0

