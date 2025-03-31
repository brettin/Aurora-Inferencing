#!/bin/bash
#
#
mkdir -p /tmp/$DAOS_POOL/$DAOS_CONT
start-dfuse.sh -m /tmp/$DAOS_POOL/$DAOS_CONT --pool $DAOS_POOL --cont $DAOS_CONT
ls /tmp/$DAOS_POOL/$DAOS_CONT
