#!/bin/bash
# 1. Force Log to stdout (Fix red logs in Railway)
exec 2>&1
set -e

# Logging colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[Postgres-HA-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

log "Booting PostgreSQL 18 HA Entrypoint..."

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool-II Proxy..."
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    
    cat > "$PGPOOL_CONF" <<EOF
listen_addresses = '*'
port = 5432
pcp_port = 9898
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'

backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_weight1 = 1
backend_flag1 = 'ALLOW_TO_FAILOVER'

backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'

# Authentication: Pass-through
enable_pool_hba = off
pool_passwd = ''

# Health Check & SR Check (Explicit database to fix status -2)
health_check_period = 10
health_check_timeout = 30
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'
health_check_database = '$POSTGRES_DB'
auto_failback = on

sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$POSTGRES_PASSWORD'
sr_check_database = '$POSTGRES_DB'

num_init_children = 32
max_pool = 4
EOF

    log "Waiting for Primary ($PRIMARY_HOST)..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do sleep 5; done
    
    log "Launching Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" 2>&1
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY SETUP WITH RESILIENCE ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        # We use a subshell without 'set -e' to handle the transition between temp and final server
        set +e
        log "Primary: Background maintenance started (Resilience Mode)."
        
        while true; do
            # Wait for server to be responsive
            if pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; then
                log "Primary: Server is ready. Syncing credentials and extensions..."
                
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-'EOSQL' 2>&1
                    -- Set passwords safely
                    EXECUTE format('ALTER USER %I WITH PASSWORD %L', current_setting('custom.user'), current_setting('custom.pass'));
                    DO $$ 
                    BEGIN
                        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = current_setting('custom.repl_user')) THEN
                            EXECUTE format('CREATE USER %I WITH REPLICATION PASSWORD %L', current_setting('custom.repl_user'), current_setting('custom.pass'));
                        ELSE
                            EXECUTE format('ALTER USER %I WITH REPLICATION PASSWORD %L', current_setting('custom.repl_user'), current_setting('custom.pass'));
                        END IF;
                    END $$;

                    -- Setup Replication Slot
                    SELECT * FROM pg_create_physical_replication_slot('replica_slot') 
                    WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot');
                    
                    -- Setup Extensions
                    CREATE EXTENSION IF NOT EXISTS "pg_cron";
                    CREATE EXTENSION IF NOT EXISTS "pg_partman";
EOSQL

                if [ $? -eq 0 ]; then
                    log "Primary: Successfully established HA and Extension configuration."
                    
                    # Apply final HBA rules
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
                    log "Primary: Final security rules applied. Maintenance thread exiting."
                    break # Success! Exit the loop.
                else
                    warn "Primary: SQL task interrupted (likely server restart), retrying in 5s..."
                fi
            fi
            sleep 5
        done
    ) &
fi

# --- REPLICA SETUP ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Initializing sync from $PRIMARY_HOST..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do sleep 5; done
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Waiting for base backup..."
            sleep 5
        done
        log "Replica: Base backup synced."
    fi
    printf "primary_conninfo = 'host=%s port=5432 user=%s password=%s'\n" "$PRIMARY_HOST" "$REPLICATION_USER" "$POSTGRES_PASSWORD" >> "$PG_DATA/postgresql.auto.conf"
    printf "primary_slot_name = 'replica_slot'\n" >> "$PG_DATA/postgresql.auto.conf"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
fi

# Shared Config
if [ -f "$PG_DATA/postgresql.conf" ]; then
    log "Applying PostgreSQL tuning and background settings..."
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    sed -i "/^shared_preload_libraries/d" "$PG_DATA/postgresql.conf" || true
    echo "shared_preload_libraries = 'pg_stat_statements,pg_cron'" >> "$PG_DATA/postgresql.conf"
    
    # Custom settings for background task
    sed -i "/^custom./d" "$PG_DATA/postgresql.conf" || true
    echo "custom.user = '$POSTGRES_USER'" >> "$PG_DATA/postgresql.conf"
    echo "custom.pass = '$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.conf"
    echo "custom.repl_user = '$REPLICATION_USER'" >> "$PG_DATA/postgresql.conf"
    
    echo "password_encryption = scram-sha-256" >> "$PG_DATA/postgresql.conf"
    echo "log_connections = on" >> "$PG_DATA/postgresql.conf"
    echo "cron.database_name = '$POSTGRES_DB'" >> "$PG_DATA/postgresql.conf"
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Starting PostgreSQL 18..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
