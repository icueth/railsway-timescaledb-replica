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

# Health Check & SR Check
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

# --- PRIMARY SETUP ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        set +e
        log "Primary: Background maintenance thread started."
        
        while true; do
            # We wait for the server to be ready and for the database to exist
            if pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; then
                log "Primary: Server is ready. Running maintenance tasks..."
                
                # Pass variables via psql -v to handle special characters and avoid "current_setting" errors
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                     -v usr="$POSTGRES_USER" \
                     -v pwd="$POSTGRES_PASSWORD" \
                     -v r_usr="$REPLICATION_USER" \
                     -v db_name="$POSTGRES_DB" <<-'EOSQL' 2>&1
                    DO $$ 
                    BEGIN
                        -- Sync main user password
                        EXECUTE format('ALTER USER %I WITH PASSWORD %L', :'usr', :'pwd');
                        
                        -- Ensure replication user
                        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = :'r_usr') THEN
                            EXECUTE format('CREATE USER %I WITH REPLICATION PASSWORD %L', :'r_usr', :'pwd');
                        ELSE
                            EXECUTE format('ALTER USER %I WITH REPLICATION PASSWORD %L', :'r_usr', :'pwd');
                        END IF;
                    END $$;

                    -- Replication Slot
                    SELECT * FROM pg_create_physical_replication_slot('replica_slot') 
                    WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot');
                    
                    -- Extensions (Note: pg_cron requires cron.database_name to be set in postgresql.conf)
                    -- We try to create them; if pg_cron fails because of config lag, we'll retry next loop
                    CREATE EXTENSION IF NOT EXISTS "pg_cron";
                    CREATE EXTENSION IF NOT EXISTS "pg_partman";
EOSQL

                if [ $? -eq 0 ]; then
                    log "Primary: HA and Extension configuration successful."
                    
                    # Update pg_hba.conf one last time to ensure it is correct
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
                    warn "Primary: SQL tasks failed or server restarted, retrying in 5s..."
                fi
            fi
            sleep 5
        done
    ) &
fi

# --- REPLICA SETUP ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    log "Replica: Initializing sync logic..."
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Cloning data from $PRIMARY_HOST..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do sleep 5; done
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Waiting for primary to be ready for backup..."
            sleep 5
        done
        log "Replica: Sync complete."
    fi
    printf "primary_conninfo = 'host=%s port=5432 user=%s password=%s'\n" "$PRIMARY_HOST" "$REPLICATION_USER" "$POSTGRES_PASSWORD" > "$PG_DATA/postgresql.auto.conf"
    printf "primary_slot_name = 'replica_slot'\n" >> "$PG_DATA/postgresql.auto.conf"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
fi

# Shared Configuration (applied to Primary and Replica)
if [ -f "$PG_DATA/postgresql.conf" ]; then
    log "Configuring postgresql.conf..."
    # Force stdout logging
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    
    # Configure Libraries
    sed -i "/^shared_preload_libraries/d" "$PG_DATA/postgresql.conf" || true
    echo "shared_preload_libraries = 'pg_stat_statements,pg_cron'" >> "$PG_DATA/postgresql.conf"
    
    # Configure pg_cron database
    sed -i "/^cron.database_name/d" "$PG_DATA/postgresql.conf" || true
    echo "cron.database_name = '${POSTGRES_DB:-postgres}'" >> "$PG_DATA/postgresql.conf"
    
    # General Security
    sed -i "/^password_encryption/d" "$PG_DATA/postgresql.conf" || true
    echo "password_encryption = scram-sha-256" >> "$PG_DATA/postgresql.conf"
    
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Starting PostgreSQL 18 HA node in $NODE_ROLE mode..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
