#!/bin/bash
# Entrypoint for PROXY node only (Pgpool-II)
# Version 2.0 - Enhanced with Auto-Failback and Better Recovery
exec 2>&1
set -e

# Logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-PROXY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

log "Starting Pgpool-II Proxy v2.0 (Debian/Pgpool 4.7)..."
log "Config: USER=$POSTGRES_USER, DB=$POSTGRES_DB"

# Signal handlers for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    pkill -TERM pgpool 2>/dev/null || true
    sleep 2
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# Create directories
mkdir -p /var/run/pgpool /var/log/pgpool /tmp
chmod 777 /tmp

PGPOOL_CONF="/etc/pgpool2/pgpool.conf"
PCP_CONF="/etc/pgpool2/pcp.conf"

# Escape single quotes in password
ESCAPED_PASSWORD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")

# Create PCP password file for attach node commands
PCP_PASSWORD_HASH=$(echo -n "${POSTGRES_USER}${POSTGRES_PASSWORD}" | md5sum | cut -d' ' -f1)
echo "${POSTGRES_USER}:${PCP_PASSWORD_HASH}" > "$PCP_CONF"

log "Configuring Pgpool-II with enhanced failback..."

cat > "$PGPOOL_CONF" <<EOF
# Pgpool-II 4.7 Configuration for TimescaleDB HA
# Enhanced with Auto-Failback and Better Recovery

listen_addresses = '*'
port = 5432
pcp_listen_addresses = '*'
pcp_port = 9898

# Unix socket
unix_socket_directories = '/var/run/pgpool,/tmp'
pcp_socket_dir = '/var/run/pgpool'

# Backend nodes
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'
backend_data_directory0 = '/var/lib/postgresql/data'

backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_weight1 = 1
backend_flag1 = 'ALLOW_TO_FAILOVER'
backend_data_directory1 = '/var/lib/postgresql/data'

# Clustering mode
backend_clustering_mode = 'streaming_replication'
load_balance_mode = on

# Session handling for TimescaleDB/pgx compatibility
statement_level_load_balance = on
disable_load_balance_on_write = 'off'
allow_sql_comments = on

# Load balance preferences - force standby for reads
database_redirect_preference_list = 'postgres:standby'
app_name_redirect_preference_list = 'psql:standby,pgadmin:standby,dbeaver:standby'

# Allow all functions to be load balanced (empty = all allowed)
black_function_list = ''
white_function_list = ''
black_query_pattern_list = ''

# Authentication: Pass-through to backend
enable_pool_hba = off
pool_passwd = ''
allow_clear_text_frontend_auth = on

# Health Check - More aggressive for Railway environment
health_check_period = 5
health_check_timeout = 20
health_check_user = '$POSTGRES_USER'
health_check_password = '$ESCAPED_PASSWORD'
health_check_database = '$POSTGRES_DB'
health_check_max_retries = 5
health_check_retry_delay = 2
connect_timeout = 10000

# Auto failback when replica comes back online
auto_failback = on
auto_failback_interval = 30

# Failover behavior - Less aggressive to avoid false positives
failover_on_backend_error = off
failover_on_backend_shutdown = off
detach_false_primary = on

# Streaming Replication Check
sr_check_period = 5
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$ESCAPED_PASSWORD'
sr_check_database = '$POSTGRES_DB'
delay_threshold = 10000000

# Logging
log_destination = 'stderr'
log_line_prefix = '%t: pid %p: '
log_connections = off
log_disconnections = off
log_hostname = off
log_statement = off
log_per_node_statement = off
log_client_messages = off
log_min_messages = error

# Connection pooling
num_init_children = 32
max_pool = 4
child_life_time = 300
child_max_connections = 0
connection_life_time = 0
client_idle_limit = 0

# Memory cache (disabled for simplicity)
memory_cache_enabled = off

# Watchdog (disabled - single proxy)
use_watchdog = off

# PID file
pid_file_name = '/var/run/pgpool/pgpool.pid'
logdir = '/var/log/pgpool'
EOF

log "Waiting for Primary ($PRIMARY_HOST)..."
until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do 
    warn "Primary not ready, waiting..."
    sleep 5
done

# Background node monitor for manual re-attach if auto_failback fails
(
    set +e
    log "Starting background node monitor..."
    sleep 60  # Wait for pgpool to fully start
    
    while true; do
        sleep 60
        
        # Check if replica is healthy but detached
        if pg_isready -h "$REPLICA_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; then
            # Check if replica is in Pgpool
            NODE_STATUS=$(PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -n 1 2>/dev/null | cut -d' ' -f3 || echo "unknown")
            
            if [ "$NODE_STATUS" = "down" ] || [ "$NODE_STATUS" = "3" ]; then
                log "Detected healthy replica is detached, attempting to attach..."
                PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_attach_node -h localhost -p 9898 -U "$POSTGRES_USER" -n 1 2>&1 || true
            fi
        fi
        
        # Log cluster status periodically
        log "Cluster status:"
        for i in 0 1; do
            STATUS=$(PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -n $i 2>/dev/null || echo "error")
            echo "  Node $i: $STATUS"
        done
    done
) &

log "Primary is ready! Launching Pgpool-II..."
exec pgpool -n -f "$PGPOOL_CONF" 2>&1
