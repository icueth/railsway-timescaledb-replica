#!/bin/bash
# Enhanced Healthcheck for TimescaleDB HA (PRIMARY, REPLICA, PROXY)
# Version 2.0 - Includes replication status checks

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
elif [ "$NODE_ROLE" = "REPLICA" ]; then
    # Check PostgreSQL is running
    if ! pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
        echo "PostgreSQL not ready"
        exit 1
    fi
    
    # Check if in recovery mode (standby)
    IS_REPLICA=$(psql -h localhost -U postgres -d postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    if [ "$IS_REPLICA" != "t" ]; then
        echo "Not in recovery mode: $IS_REPLICA"
        exit 1
    fi
    
    # Check replication lag (warn if > 5 minutes but still healthy)
    LAG_SECONDS=$(psql -h localhost -U postgres -d postgres -tAc \
        "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, 0);" 2>/dev/null || echo "0")
    
    if [ "$LAG_SECONDS" -gt 300 ]; then
        echo "High replication lag: ${LAG_SECONDS}s"
        # Still return healthy for now, but log warning
    fi
    
    exit 0
else
    # PRIMARY: Check PostgreSQL
    if ! pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
        echo "PostgreSQL not ready"
        exit 1
    fi
    
    # Check we're NOT in recovery (should be primary)
    IS_REPLICA=$(psql -h localhost -U postgres -d postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    if [ "$IS_REPLICA" = "t" ]; then
        echo "Node is in recovery mode but should be PRIMARY"
        exit 1
    fi
    
    exit 0
fi
