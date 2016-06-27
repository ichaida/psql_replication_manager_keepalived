#!/usr/bin/env bash

PSQL_REMOTEIP=""

# We import the code of common functions
. common_functions.sh || exit 1

# Calling transition to slave
transit_to_slave "${PSQL_REMOTEIP}"

exit 0

