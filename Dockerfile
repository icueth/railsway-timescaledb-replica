FROM timescale/timescaledb:latest-pg17

# Install useful tools, replication dependencies and Pgpool-II
RUN apk add --no-cache bash sudo iputils wget curl pgpool

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

# Healthcheck
HEALTHCHECK --interval=10s --timeout=5s --retries=5 CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-custom.sh"]
