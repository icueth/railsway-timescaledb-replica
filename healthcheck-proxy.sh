#!/bin/bash
# Healthcheck for Pgpool-II Proxy

# Check if pgpool process is running
if ! pgrep -x "pgpool" > /dev/null 2>&1; then
    echo "Pgpool process not running"
    exit 1
fi

# Check if we can connect via pgpool
if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
    exit 0
else
    echo "Cannot connect to pgpool"
    exit 1
fi
