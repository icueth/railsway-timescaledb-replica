#!/bin/bash
# Enhanced Healthcheck for Pgpool-II Proxy
# Version 2.0 - Includes backend node status

# Check if pgpool process is running
if ! pgrep -x "pgpool" > /dev/null 2>&1; then
    echo "Pgpool process not running"
    exit 1
fi

# Check if we can connect via pgpool
if ! pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
    echo "Cannot connect to pgpool"
    exit 1
fi

# Check if at least primary is available
PRIMARY_STATUS=$(PGPOOL_PCP_PASSWORD="${POSTGRES_PASSWORD}" pcp_node_info -h localhost -p 9898 -U "${POSTGRES_USER:-postgres}" -n 0 2>/dev/null | cut -d' ' -f3 || echo "unknown")

if [ "$PRIMARY_STATUS" = "3" ] || [ "$PRIMARY_STATUS" = "down" ]; then
    echo "Primary node is down"
    exit 1
fi

exit 0
