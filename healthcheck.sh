#!/bin/bash
# Unified Healthcheck for TimescaleDB HA (PRIMARY, REPLICA, PROXY)

NODE_ROLE="${NODE_ROLE:-PRIMARY}"

if [ "$NODE_ROLE" = "PROXY" ]; then
    # Check Pgpool process
    if ! pgrep -x "pgpool" > /dev/null 2>&1; then
        echo "Pgpool process not running"
        exit 1
    fi
    # Check Pgpool connection
    if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
        exit 0
    else
        echo "Cannot connect to pgpool"
        exit 1
    fi
else
    # Check PostgreSQL
    if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
        exit 0
    else
        echo "PostgreSQL not ready"
        exit 1
    fi
fi
