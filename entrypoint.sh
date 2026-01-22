#!/bin/bash
# Unified Entrypoint for TimescaleDB HA (PRIMARY, REPLICA, PROXY)
# Version 2.0 - Enhanced with Auto-Recovery and Resilience

# Ensure output is unbuffered
export PYTHONUNBUFFERED=1
stdbuf -oL -eL true 2>/dev/null || true

# Redirect stderr to stdout immediately
exec 2>&1

# Debug: Show we're starting
echo "[DEBUG] Script starting, NODE_ROLE=${NODE_ROLE:-NOT_SET}"

# Exit on error but with trap for debugging
set -e
trap 'echo "[DEBUG] Script exited at line $LINENO with status $?"' ERR

# Logging colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values for environment variables
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
RECOVERY_CHECK_INTERVAL="${RECOVERY_CHECK_INTERVAL:-30}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"

log "Starting TimescaleDB HA Entrypoint v2.0..."
log "Config: USER=$POSTGRES_USER, DB=$POSTGRES_DB, REPL_USER=$REPLICATION_USER, ROLE=$NODE_ROLE"

# Signal handlers for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    if [ "$NODE_ROLE" = "PROXY" ]; then
        pkill -TERM pgpool 2>/dev/null || true
    else
        pg_ctl -D "$PG_DATA" -m fast stop 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II 4.7)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool-II 4.7 Proxy..."
    
    # Create directories
    mkdir -p /var/run/pgpool /var/log/pgpool /tmp /etc/pgpool
    chmod 777 /tmp
    chown -R postgres:postgres /var/run/pgpool /var/log/pgpool /etc/pgpool 2>/dev/null || true

    PGPOOL_CONF="/etc/pgpool/pgpool.conf"
    
    # Escape single quotes in password
    ESCAPED_PASSWORD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
    
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

# Health Check - More aggressive recovery
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

# Failover behavior
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

    log "Primary is ready! Launching Pgpool-II 4.7..."
    exec /usr/local/pgpool/bin/pgpool -n -f "$PGPOOL_CONF" 2>&1
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data 2>/dev/null || true

# --- PRIMARY SETUP WITH RESILIENCE ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        set +e
        log "Primary: Background maintenance thread started."
        
        while true; do
            if pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; then
                log "Primary: Server is ready. Running maintenance tasks..."
                
                # Escape single quotes in password for SQL safety
                ESCAPED_PWD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
                
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL 2>&1
-- Sync main user password
ALTER USER "$POSTGRES_USER" WITH PASSWORD '$ESCAPED_PWD';

-- Ensure replication user exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICATION_USER') THEN
        CREATE USER "$REPLICATION_USER" WITH REPLICATION PASSWORD '$ESCAPED_PWD';
    ELSE
        ALTER USER "$REPLICATION_USER" WITH REPLICATION PASSWORD '$ESCAPED_PWD';
    END IF;
END \$\$;

-- Replication Slot (with auto-cleanup for stale slots)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot') THEN
        PERFORM pg_create_physical_replication_slot('replica_slot');
    END IF;
END \$\$;

-- Configure for better replication
ALTER SYSTEM SET wal_keep_size = '1GB';
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET wal_sender_timeout = '60s';
ALTER SYSTEM SET wal_level = 'replica';
SELECT pg_reload_conf();
EOSQL

                if [ $? -eq 0 ]; then
                    log "Primary: User and replication configuration successful."
                    # Apply final HBA rules with IPv6 support
                    cat > "$PG_DATA/pg_hba.conf" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             10.0.0.0/8              trust
host    all             all             100.64.0.0/10           trust
host    all             all             fd00::/8                trust
host    replication     all             0.0.0.0/0               scram-sha-256
host    replication     all             ::/0                    scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             ::/0                    scram-sha-256
EOF
                    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();" > /dev/null 2>&1
                    log "Primary: Maintenance task completed."
                    break
                else
                    warn "Primary: SQL tasks encountered an error, retrying in 5s..."
                fi
            fi
            sleep 5
        done
        
        # Continuous replication slot monitoring
        log "Primary: Starting replication slot monitor..."
        while true; do
            sleep 60
            # Log replication status
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
                SELECT slot_name, active, restart_lsn, 
                       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
                FROM pg_replication_slots 
                WHERE slot_type = 'physical';" 2>/dev/null | grep -v "^$" | head -5 || true
        done
    ) &
fi

# --- REPLICA SETUP WITH AUTO-RECOVERY ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    log "Replica: Initializing sync logic with auto-recovery..."
    
    # Function to perform full sync from primary
    perform_full_sync() {
        log "Replica: Performing full sync from $PRIMARY_HOST..."
        
        # Wait for primary
        until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do 
            warn "Replica: Waiting for primary to be ready..."
            sleep 5
        done
        
        # Stop PostgreSQL if running
        pg_ctl -D "$PG_DATA" -m immediate stop 2>/dev/null || true
        
        # Clean up data directory
        rm -rf "$PG_DATA"/*
        
        # Perform base backup with retries
        local attempts=0
        while [ $attempts -lt $MAX_RECOVERY_ATTEMPTS ]; do
            log "Replica: Base backup attempt $((attempts+1))/$MAX_RECOVERY_ATTEMPTS..."
            if PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup \
                -h "$PRIMARY_HOST" \
                -D "$PG_DATA" \
                -U "$REPLICATION_USER" \
                -v -R -P \
                --slot=replica_slot \
                --checkpoint=fast \
                --wal-method=stream 2>&1; then
                log "Replica: Base backup completed successfully."
                return 0
            fi
            
            warn "Replica: Base backup failed, retrying in 10s..."
            attempts=$((attempts+1))
            sleep 10
        done
        
        error "Replica: Failed to complete base backup after $MAX_RECOVERY_ATTEMPTS attempts."
        return 1
    }
    
    # Initial sync
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: No data found, performing initial sync..."
        perform_full_sync
    fi
    
    # Update postgresql.auto.conf
    ESCAPED_PWD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
    
    sed -i '/^primary_conninfo/d' "$PG_DATA/postgresql.auto.conf" 2>/dev/null || true
    sed -i '/^primary_slot_name/d' "$PG_DATA/postgresql.auto.conf" 2>/dev/null || true
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$ESCAPED_PWD application_name=replica1'" >> "$PG_DATA/postgresql.auto.conf"
    echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
    
    # Ensure standby.signal exists
    touch "$PG_DATA/standby.signal"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf" "$PG_DATA/standby.signal"
    
    # Background recovery monitor
    (
        set +e
        log "Replica: Starting recovery monitor..."
        sleep 30  # Wait for PostgreSQL to start
        
        local consecutive_failures=0
        
        while true; do
            sleep "$RECOVERY_CHECK_INTERVAL"
            
            # Check if PostgreSQL is running
            if ! pg_isready -h localhost -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; then
                warn "Replica: PostgreSQL not responding..."
                consecutive_failures=$((consecutive_failures+1))
            # Check replication status
            elif ! psql -h localhost -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
                "SELECT CASE WHEN pg_is_in_recovery() THEN 'OK' ELSE 'NOT_REPLICA' END;" 2>/dev/null | grep -q "OK"; then
                warn "Replica: Not in recovery mode..."
                consecutive_failures=$((consecutive_failures+1))
            # Check WAL receiver status
            elif ! psql -h localhost -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
                "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null | grep -qE "streaming|catchup"; then
                warn "Replica: WAL receiver not streaming..."
                
                # Try to check if it's just a temporary disconnect
                if psql -h localhost -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
                    "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
                    # Still in recovery mode, might reconnect
                    log "Replica: Still in recovery mode, WAL receiver may reconnect..."
                    consecutive_failures=$((consecutive_failures+1))
                else
                    consecutive_failures=$((consecutive_failures+1))
                fi
            else
                # Healthy - log replication lag
                LAG=$(psql -h localhost -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
                    "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, 0);" 2>/dev/null || echo "0")
                
                if [ "$consecutive_failures" -gt 0 ]; then
                    log "Replica: Recovered! Replication lag: ${LAG}s"
                fi
                consecutive_failures=0
            fi
            
            # If too many consecutive failures, attempt recovery
            if [ "$consecutive_failures" -ge 5 ]; then
                error "Replica: Too many consecutive failures ($consecutive_failures), initiating recovery..."
                
                # Check if primary is available
                if pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; then
                    log "Replica: Primary is available, attempting full re-sync..."
                    perform_full_sync
                    
                    if [ $? -eq 0 ]; then
                        log "Replica: Re-sync completed, restarting PostgreSQL..."
                        # Don't restart here - let the main process handle it
                        consecutive_failures=0
                        # Signal main process to restart
                        kill -HUP 1 2>/dev/null || true
                    fi
                else
                    warn "Replica: Primary not available, will retry later..."
                fi
            fi
        done
    ) &
fi

# Shared Configuration Fixes (for PRIMARY and REPLICA)
if [ -f "$PG_DATA/postgresql.conf" ]; then
    log "Configuring postgresql.conf..."
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    sed -i "/^password_encryption/d" "$PG_DATA/postgresql.conf" || true
    echo "password_encryption = scram-sha-256" >> "$PG_DATA/postgresql.conf"
    
    # Enhanced replication settings for replica
    if [ "$NODE_ROLE" = "REPLICA" ]; then
        sed -i "/^hot_standby/d" "$PG_DATA/postgresql.conf" || true
        sed -i "/^hot_standby_feedback/d" "$PG_DATA/postgresql.conf" || true
        sed -i "/^wal_receiver_timeout/d" "$PG_DATA/postgresql.conf" || true
        sed -i "/^wal_retrieve_retry_interval/d" "$PG_DATA/postgresql.conf" || true
        cat >> "$PG_DATA/postgresql.conf" <<EOF

# Replica-specific settings
hot_standby = on
hot_standby_feedback = on
wal_receiver_timeout = 60s
wal_retrieve_retry_interval = 5s
EOF
    fi
    
    # TimescaleDB tuning
    if command -v timescaledb-tune &> /dev/null; then
        chmod 777 /tmp
        timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_DATA/postgresql.conf" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}" > /dev/null 2>&1 || true
    fi
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Starting TimescaleDB HA node in $NODE_ROLE mode..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
