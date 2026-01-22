# Multi-role Dockerfile for TimescaleDB HA
# Supports PRIMARY, REPLICA, and PROXY roles via NODE_ROLE environment variable
# Version 2.0 - Enhanced with better recovery support

# Stage 1: Build Pgpool 4.7 from source
FROM alpine:3.20 AS pgpool-builder

RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    linux-headers \
    openssl-dev \
    curl

# Download and compile Pgpool-II 4.7.0
RUN curl -fsSL https://www.pgpool.net/mediawiki/images/pgpool-II-4.7.0.tar.gz | tar xz && \
    cd pgpool-II-4.7.0 && \
    ./configure --prefix=/usr/local/pgpool --with-openssl && \
    make -j$(nproc) && \
    make install

# Stage 2: Final image with TimescaleDB + Pgpool 4.7
FROM timescale/timescaledb:latest-pg17

# Copy Pgpool 4.7 from builder
COPY --from=pgpool-builder /usr/local/pgpool /usr/local/pgpool

# Add Pgpool to PATH
ENV PATH="/usr/local/pgpool/bin:$PATH"

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    sudo \
    iputils \
    wget \
    curl \
    libpq \
    openssl \
    procps \
    postgresql17-client

# Create Pgpool directories
RUN mkdir -p /var/run/pgpool /var/log/pgpool /etc/pgpool && \
    chown -R postgres:postgres /var/run/pgpool /var/log/pgpool /etc/pgpool

# Copy scripts
COPY entrypoint.sh /usr/local/bin/entrypoint-custom.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

# Make executable
RUN chmod +x /usr/local/bin/entrypoint-custom.sh /usr/local/bin/healthcheck.sh

# Set environment defaults
ENV POSTGRES_DB=postgres
ENV POSTGRES_USER=postgres
ENV TS_TUNE_MEMORY=2GB
ENV TS_TUNE_CORES=2
ENV REPLICATION_USER=replicator
ENV NODE_ROLE=PRIMARY
ENV TZ=Asia/Bangkok
ENV RECOVERY_CHECK_INTERVAL=30
ENV MAX_RECOVERY_ATTEMPTS=3

# Healthcheck with better intervals
HEALTHCHECK --interval=15s --timeout=10s --retries=3 --start-period=30s CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-custom.sh"]
