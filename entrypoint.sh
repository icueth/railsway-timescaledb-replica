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
    
    # Fix: Create directory for pgpool PID file
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

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

# 1. แเตรียมความพร้อมของโฟลเดอร์สำหรับ Postgres
if [ "$NODE_ROLE" != "PROXY" ]; then
    mkdir -p "$PG_DATA"
    chown -R postgres:postgres /var/lib/postgresql/data
fi

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Advanced Pgpool-II..."
    
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    POOL_HBA="/etc/pool_hba.conf"
    POOL_PASSWD="/etc/pool_passwd"
    
    # สร้าง pool_passwd (ใช้สำหรับให้ Proxy คุยกับ Backend)
    # รูปแบบ: username:password
    echo "$POSTGRES_USER:$(echo -n "$POSTGRES_PASSWORD" | md5sum | awk '{print "md5"$1}')" > "$POOL_PASSWD"
    chown postgres:postgres "$POOL_PASSWD"
    chmod 600 "$POOL_PASSWD"

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

num_init_children = 32
max_pool = 4
child_life_time = 300
connection_life_time = 0
client_idle_limit = 0

backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'
replication_mode = off

health_check_period = 10
health_check_timeout = 5
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'

enable_pool_hba = on
pool_passwd = '$POOL_PASSWD'
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    log "Starting Proxy on port 5432..."
    exec pgpool -n -f "$PGPOOL_CONF" -a "$POOL_HBA"
fi

# 2. Logic สำหรับ PRIMARY
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    INIT_DIR="/docker-entrypoint-initdb.d"
    mkdir -p "$INIT_DIR"
    
    cat > "$INIT_DIR/01_setup_replication.sh" <<EOF
#!/bin/bash
set -e
echo "host replication $REPLICATION_USER 0.0.0.0/0 md5" >> "\$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 md5" >> "\$PGDATA/pg_hba.conf"

psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" --dbname "\$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICATION_USER') THEN
            CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';
        END IF;
    END
    \$\$;
    SELECT * FROM pg_create_physical_replication_slot('replica_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot');
EOSQL
EOF
    chmod +x "$INIT_DIR/01_setup_replication.sh"

    cat > "$INIT_DIR/02_timescale_best_practices.sql" <<EOF
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
ALTER SYSTEM SET timescaledb.telemetry_level = 'off';
EOF
fi

# 3. Logic สำหรับ REPLICA (อดทนต่อการ Deploy พร้อมกัน)
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica mode: Initializing data sync..."
        
        # รอจนกว่า Primary จะตอบสนองทาง Network (ป้องกัน DNS ยังไม่พร้อม)
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do
            warn "Primary ($PRIMARY_HOST) is not reachable yet. Waiting 5s..."
            sleep 5
        done

        rm -rf "$PG_DATA"/*
        
        # ใช้ sudo -E เพื่อคงค่า PGPASSWORD ไว้ และรัน pg_basebackup จนกว่าจะสำเร็จ
        until PGPASSWORD="$POSTGRES_PASSWORD" sudo -E -u postgres pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Sync failed (Primary might be initializing). Retrying in 5s..."
            sleep 5
        done
        
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD replication_slot=replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
        chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
        log "Data sync from Primary completed."
    fi
fi

# Auto-tuning
if [ -f "$PG_CONF" ]; then
    # Fix permission denied on /tmp and skip backup to avoid tuning crash
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_CONF" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}"
    chown postgres:postgres "$PG_CONF"
fi

# กรณี Proxy ก็ต้องรอ Primary เหมือนกัน
if [ "$NODE_ROLE" = "PROXY" ]; then
    until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do
        warn "Proxy waiting for Primary..."
        sleep 5
    done
fi

exec docker-entrypoint.sh postgres
