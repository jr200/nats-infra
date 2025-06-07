#!/bin/sh

if [ ! -f /config/resolver.conf ]; then
  echo "Initialising NATS operator, accounts and resolver..."

  nsc add operator --generate-signing-key --sys -n infra-dev-nats
  nsc edit operator --require-signing-keys --account-jwt-server-url "nats://${NATS_HOSTNAME}:${NATS_PORT}"

  cat <<- EOF > /config/nats-server.conf
server_name: "test_server"
logtime: true
debug: true
trace: false

# Client port for nats server on all interfaces
port: ${NATS_PORT}

# HTTP monitoring port
# monitor_port: 8222
http_port: ${NATS_HTTP_PORT}

max_payload: 8M

jetstream {
    store_dir: /jsdata

    # Maximum memory for in-memory streams.
    max_memory_store: 512M

    # Maximum memory for disk streams.
    max_file_store: 1G
}

websocket: {
    port: ${NATS_WEBSOCKET_PORT}
    no_tls: true
}

include resolver.conf
EOF

  nsc generate config \
      --nats-resolver \
      --sys-account SYS > /config/resolver.conf
fi

echo "Waiting for other containers to start..."
sleep 5s

echo "Pushing operator, accounts, users..."
nsc push -A

echo sleeping...
sleep 365d
