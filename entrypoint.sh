#!/bin/bash
# 1. บังคับหันเห Log ทุกอย่าง (stdout/stderr) ไปที่ stdout เพื่อแก้ปัญหาสีแดงใน Railway
exec 2>&1
set -e

log() { echo -e "\033[0;32m[Timescale-$NODE_ROLE]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log "Starting entrypoint script..."

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool-II Proxy..."
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
backend_flag0 = 'ALLOW_TO_FAILOVER'
backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_flag1 = 'ALLOW_TO_FAILOVER'

backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'

# Authentication: ส่งต่อให้ Backend เช็คเอง (ลดปัญหา Password mismatch)
enable_pool_hba = off
pool_passwd = ''

# Health Check & Replication Check
health_check_period = 10
health_check_timeout = 30
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'

sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$POSTGRES_PASSWORD'

# Pool Settings
num_init_children = 64
max_pool = 4
child_life_time = 300
EOF

    log "Waiting for Primary ($PRIMARY_HOST)..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
    
    log "Launching Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" 2>&1
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY SETUP (Background Repair) ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        log "Primary: Background maintenance started."
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 3; done
        
        log "Primary: Syncing authentication and replication slots..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
            -- มั่นใจว่าเป็น SCRAM-SHA-256 ตามมาตรฐาน PG16
            ALTER USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';
            DO \$\$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICATION_USER') THEN
                    CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';
                ELSE
                    ALTER USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';
                END IF;
            END \$\$;
            SELECT * FROM pg_create_physical_replication_slot('replica_slot') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot');
EOSQL
        
        log "Primary: Writing failsafe pg_hba.conf..."
        # อนุญาต Trust เฉพาะ Network ภายในของ Railway เพื่อความเสถียรสูงสุด
        cat > "$PG_DATA/pg_hba.conf" <<EOF
# Type  Database        User            Address                 Method
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             10.0.0.0/8              trust
host    all             all             100.64.0.0/10           trust
host    replication     all             0.0.0.0/0               scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
EOF
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
        log "Primary: Configuration successful."
    ) &
fi

# --- REPLICA SETUP ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Initializing base backup from $PRIMARY_HOST..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Backup in progress..."
            sleep 5
        done
    fi
    # อัปเดตข้อมูลการเชื่อมต่อเสมอเพื่อให้ทันรหัสผ่านใหม่
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.auto.conf"
    echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
fi

# Final Maintenance for all DB nodes
if [ -f "$PG_DATA/postgresql.conf" ]; then
    log "Tuning PostgreSQL configuration..."
    # บังคับใช้ scram-sha-256 และปิด logging_collector เพื่อแก้ปัญหาสีแดง
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    echo "password_encryption = scram-sha-256" >> "$PG_DATA/postgresql.conf"
    
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_DATA/postgresql.conf" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}" > /dev/null 2>&1 || true
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Booting PostgreSQL system..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
