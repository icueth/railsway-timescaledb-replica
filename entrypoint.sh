#!/bin/bash
set -e

# Colors for logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

log "Starting entrypoint script for role: $NODE_ROLE"

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool-II Proxy..."
    
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    POOL_HBA="/etc/pool_hba.conf"
    POOL_PASSWD="/etc/pool_passwd"
    
    # Generate MD5 password for backend auth
    echo "$POSTGRES_USER:$(echo -n "$POSTGRES_PASSWORD" | md5sum | awk '{print "md5"$1}')" > "$POOL_PASSWD"
    chown postgres:postgres "$POOL_PASSWD"
    chmod 600 "$POOL_PASSWD"

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
num_init_children = 32
max_pool = 4
child_life_time = 300
backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'
health_check_period = 10
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'
enable_pool_hba = on
pool_passwd = '$POOL_PASSWD'
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    
    log "Waiting for Primary ($PRIMARY_HOST) before starting Proxy..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
    
    log "Starting Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" -a "$POOL_HBA"
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
PG_CONF="$PG_DATA/postgresql.conf"

# Ensure data directory exists and has correct permissions
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY LOGIC ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    log "Initializing Primary Node..."
    
    # Auto-Repair background task
    (
        log "Primary: Background maintenance started."
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 2; done
        
        log "Primary: Configuring replication user and slot..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';" || true
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_create_physical_replication_slot('replica_slot');" || true
        
        if ! grep -q "replication $REPLICATION_USER" "$PG_DATA/pg_hba.conf"; then
            sed -i "1ihost replication $REPLICATION_USER 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            sed -i "1ihost all all 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
        fi
        log "Primary: Maintenance task finished."
    ) &
fi

# --- REPLICA LOGIC ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica mode: Initializing sync from $PRIMARY_HOST..."
        
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do
            warn "Waiting for Primary ($PRIMARY_HOST)..."
            sleep 5
        done

        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" sudo -E -u postgres pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Sync failed, retrying in 5s..."
            sleep 5
        done
        
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD replication_slot=replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
        chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
        log "Sync from Primary completed."
    fi
fi

# Final Auto-tuning
if [ -f "$PG_CONF" ]; then
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_CONF" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}"
    chown postgres:postgres "$PG_CONF"
fi

log "Booting PostgreSQL..."
exec docker-entrypoint.sh postgres
