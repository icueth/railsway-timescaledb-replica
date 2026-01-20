#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Advanced Pgpool-II..."
    
    PGPOOL_CONF="/etc/pgpool.conf"
    POOL_HBA="/etc/pool_hba.conf"
    
    cat > "$PGPOOL_CONF" <<EOF
listen_addresses = '*'
port = 5432
pcp_port = 9898
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_weight0 = ${PRIMARY_WEIGHT:-1}
backend_flag0 = 'ALLOW_TO_FAILOVER'

backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_weight1 = ${REPLICA_WEIGHT:-1}
backend_flag1 = 'ALLOW_TO_FAILOVER'

# --- Performance & Pooling ---
num_init_children = 32
max_pool = 4
child_life_time = 300
connection_life_time = 0
client_idle_limit = 0

# --- Read/Write splitting ---
backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'
replication_mode = off

# --- Health Check ---
health_check_period = 10
health_check_timeout = 5
health_check_user = '$POSTGRES_USER'

enable_pool_hba = on
pool_passwd = ''
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    log "Starting Proxy on port 5432..."
    exec pgpool -n
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
PG_CONF="$PG_DATA/postgresql.conf"

# Initialization for Primary (Maintenance Policies)
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    INIT_DIR="/docker-entrypoint-initdb.d"
    mkdir -p "$INIT_DIR"
    
    # สคริปต์สำหรับตั้งค่า TimescaleDB Best Practices อัตโนมัติ
    cat > "$INIT_DIR/02_timescale_best_practices.sql" <<EOF
-- เปิดใช้งาน Extension
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- ตัวอย่าง: ตั้งค่า Telemetry off (Optional)
ALTER SYSTEM SET timescaledb.telemetry_level = 'off';

-- หมายเหตุ: การสร้าง Policy ต้องทำหลังจากสร้าง Table แล้ว
-- แต่เราสามารถตั้งค่า Default งานระบบไว้ที่นี่ได้
EOF
fi

# (Logic สำหรับ REPLICA ซิงค์ข้อมูลเหมือนเดิม)
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Syncing data from Primary ($PRIMARY_HOST)..."
        rm -rf "$PG_DATA"/*
        export PGPASSWORD="$POSTGRES_PASSWORD"
        until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER"; do sleep 5; done
        pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot
    fi
fi

# Auto-tuning before boot
if [ -f "$PG_CONF" ]; then
    timescaledb-tune --quiet --yes --conf-path="$PG_CONF" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}"
fi

exec docker-entrypoint.sh postgres
