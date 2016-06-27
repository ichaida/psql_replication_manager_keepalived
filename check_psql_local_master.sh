#!/usr/bin/env bash

. common_functions.sh || exit 1

check_state_keepalived "MASTER" && check_psql_local_master && exit 0

exit 1
