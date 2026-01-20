#!/bin/bash
# Entrypoint for PROXY node only (Pgpool-II)
exec 2>&1
set -e

# Logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-PROXY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Default values
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

log "Starting Pgpool-II Proxy (Debian/Pgpool 4.7)..."
log "Config: USER=$POSTGRES_USER, DB=$POSTGRES_DB"

# Create directories
mkdir -p /var/run/pgpool /var/log/pgpool /tmp
chmod 777 /tmp

PGPOOL_CONF="/etc/pgpool2/pgpool.conf"

# Escape single quotes in password
ESCAPED_PASSWORD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")

log "Configuring Pgpool-II..."

cat > "$PGPOOL_CONF" <<EOF
# Pgpool-II 4.7 Configuration for TimescaleDB HA

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
disable_load_balance_on_write = 'transaction'
allow_sql_comments = on

# Authentication: Pass-through to backend
enable_pool_hba = off
pool_passwd = ''
allow_clear_text_frontend_auth = on

# Health Check
health_check_period = 10
health_check_timeout = 30
health_check_user = '$POSTGRES_USER'
health_check_password = '$ESCAPED_PASSWORD'
health_check_database = '$POSTGRES_DB'
health_check_max_retries = 3
health_check_retry_delay = 1

# Auto failback when replica comes back online
auto_failback = on

# Streaming Replication Check
sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$ESCAPED_PASSWORD'
sr_check_database = '$POSTGRES_DB'

# Logging
log_destination = 'stderr'
log_line_prefix = '%t: pid %p: '
log_connections = off
log_disconnections = off
log_hostname = off
log_statement = off
log_per_node_statement = off
log_client_messages = off
log_min_messages = warning

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

log "Primary is ready! Launching Pgpool-II..."
exec pgpool -n -f "$PGPOOL_CONF" 2>&1
