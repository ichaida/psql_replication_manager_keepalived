#!/usr/bin/env bash

# We import necessary function's code
. common_functions.sh || exit 1

# Calling transition to master
transit_to_master

exit 0
