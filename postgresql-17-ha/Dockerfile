FROM postgres:17-bookworm

# Install PostgreSQL extensions and useful tools
RUN apt-get update && apt-get install -y \
    postgresql-17-postgis-3 \
    postgresql-17-pgvector \
    postgresql-17-cron \
    postgresql-17-partman \
    pgpool2 \
    sudo \
    bash \
    iputils-ping \
    wget \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy scripts
COPY entrypoint.sh /usr/local/bin/entrypoint-custom.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

# Initialize extensions script (runs DURING initdb, before first server start)
RUN mkdir -p /docker-entrypoint-initdb.d
COPY 00-configure-postgres.sh /docker-entrypoint-initdb.d/00-configure-postgres.sh
COPY init-extensions.sql /docker-entrypoint-initdb.d/10-init-extensions.sql

# Make executable
RUN chmod +x /usr/local/bin/entrypoint-custom.sh /usr/local/bin/healthcheck.sh \
    /docker-entrypoint-initdb.d/00-configure-postgres.sh

# Set environment defaults
ENV POSTGRES_DB=postgres
ENV POSTGRES_USER=postgres
ENV REPLICATION_USER=replicator
ENV NODE_ROLE=PRIMARY
ENV TZ=Asia/Bangkok

# Healthcheck
HEALTHCHECK --interval=10s --timeout=5s --retries=5 CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-custom.sh"]
