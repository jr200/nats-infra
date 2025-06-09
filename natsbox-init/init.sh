#!/bin/sh

set -e

if [ -z "${OPERATOR_NAME}" ]; then
    echo "Error: OPERATOR_NAME environment variable must be set"
    exit 1
fi

if [ -z "${NATS_HOSTNAME}" ]; then
    echo "Error: NATS_HOSTNAME environment variable must be set"
    exit 1
fi

if [ -z "${NATS_PORT}" ]; then
    echo "Error: NATS_PORT environment variable must be set"
    exit 1
fi

if [ -z "${NATS_HTTP_PORT}" ]; then
    echo "Error: NATS_HTTP_PORT environment variable must be set"
    exit 1
fi

if [ -z "${NATS_WEBSOCKET_PORT}" ]; then
    echo "Error: NATS_WEBSOCKET_PORT environment variable must be set"
    exit 1
fi

if [ -z "${NATS_MAX_PAYLOAD}" ]; then
    echo "Error: NATS_MAX_PAYLOAD environment variable must be set"
    exit 1
fi


if [ -f /config/resolver.conf ]; then
    echo "NATS-resolver already configured."
else
    if [ "$NATSBOX_GENERATE_OPERATOR" = "true" ]; then
        echo "No resolver found. Will generate new operator and resolver."
        nsc add operator --generate-signing-key --sys -n ${OPERATOR_NAME}
        nsc edit operator --require-signing-keys --account-jwt-server-url "nats://${NATS_HOSTNAME}:${NATS_PORT}"
        nsc generate config --nats-resolver --sys-account SYSTEM > /config/resolver.conf
    else
        echo "Error: No resolver found and generation not requested. Exiting."
        exit 1
    fi
fi

if [ -f /config/nats-server.conf ]; then
    echo "NATS-server already configured."
else
  cat <<- EOF > /config/nats-server.conf
server_name: "${NATS_SERVER_NAME}"
logtime: true
debug: true
trace: false

# Client port for nats server on all interfaces
port: ${NATS_PORT}

# HTTP monitoring port
# monitor_port: 8222
http_port: ${NATS_HTTP_PORT}

max_payload: ${NATS_MAX_PAYLOAD}

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

fi

# echo "Waiting for other containers to start..."
# sleep 5s

# echo "Pushing operator, accounts, users..."
# nsc push -A

# if [ "$NATSBOX_KEEP_ALIVE" = "true" ]; then
#     echo "NATSBOX_KEEP_ALIVE is true. Sleeping for 365 days."
#     sleep 365d
# fi
