#!/bin/bash

echo_stderr() { echo "$@" 1>&2; }

help() {
    cat << EOF 1>&2

This script creates a local NATS operator, account, and user in a local development environment.
It then imports the account credentials *into* a running NATS server.

This script requires the following environment variables:

Required:
    OPERATOR_NAME    Name of the local NATS operator to create
    ACCOUNT_NAME     Name of the local+remote NATS account to create
    USER_NAME        Name of the local NATS user to create
    NATS_CONTAINER   Name of the container running the NATS server
    NSC_CONTAINER    Name of a container that can adminster credentials on the NATS server (requires nsc).

Optional:
    NATS_URL         URL of the NATS server (default: nats://127.0.0.1:4222)
    CONTAINER_CLI    Container CLI to use, podman|docker|kubectl (default: podman)

Example:
    export OPERATOR_NAME=local-operator
    export ACCOUNT_NAME=MY-TEAM
    export USER_NAME=static-user
    export NATS_CONTAINER=nats-1
    export NSC_CONTAINER=nsc-admin-1
    export NATS_URL=nats://127.0.0.1:4222
    export CONTAINER_CLI=podman
EOF
}

# Set default NATS URL if not provided
NATS_URL=${NATS_URL:-nats://127.0.0.1:4222}
CONTAINER_CLI=${CONTAINER_CLI:-podman}

# Validate required environment variables
if [ -z "$OPERATOR_NAME" ] || [ -z "$ACCOUNT_NAME" ] || [ -z "$USER_NAME" ] || \
   [ -z "$NATS_CONTAINER" ] || [ -z "$NSC_CONTAINER" ]; then
    echo_stderr "Error: Missing required environment variables"
    help
    exit 1
fi

# ----------------------------------------------------------------------------
# Create and select the local operator
# ----------------------------------------------------------------------------
if 1>&2 nsc describe operator ${OPERATOR_NAME} &> /dev/null; then
    echo_stderr "Operator ${OPERATOR_NAME} already exists."
else
    echo_stderr "Creating new operator ${OPERATOR_NAME}..."

    1>&2 nsc add operator --generate-signing-key --sys -n ${OPERATOR_NAME}
    1>&2 nsc edit operator --require-signing-keys
fi

1>&2 nsc select operator ${OPERATOR_NAME}
echo_stderr "Selected operator ${OPERATOR_NAME}"

# ----------------------------------------------------------------------------
# Validation checks
# If the account exists on the server, it must have the same public key
# ----------------------------------------------------------------------------

echo_stderr Validating AccountId.name: ${ACCOUNT_NAME}

if nsc describe account -n ${ACCOUNT_NAME} &> /dev/null; then
    local_account_id=`nsc describe account -n ${ACCOUNT_NAME} --json | jq -r .sub | tr -d '\n'`
else
    local_account_id="?"
fi
echo_stderr "AccountId.local:  ${local_account_id}"

if ${CONTAINER_CLI} exec -it ${NSC_CONTAINER} nsc describe account -n ${ACCOUNT_NAME} &> /dev/null; then
    remote_account_id=`${CONTAINER_CLI} exec -it ${NSC_CONTAINER} nsc describe account -n ${ACCOUNT_NAME} --json | jq -r .sub | tr -d '\n'`
else
    remote_account_id="?"
fi

echo_stderr "AccountId.remote: ${remote_account_id}"

if [ "$remote_account_id" != "?" ]; then
    # remote account id exists
    if [ "$local_account_id" == "$remote_account_id" ]; then
        # local and remote account match
        echo_stderr "Local-Remote account identity validated."
    else
        #  local and remote account do not match
        echo_stderr "Error: Account ${ACCOUNT_NAME} already exists on remote with a different identity."
        echo_stderr "To delete remote account, run: "
        echo_stderr "  ${CONTAINER_CLI} exec -it ${NSC_CONTAINER} nsc delete account -n ${ACCOUNT_NAME} -C -D -R"
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Create a local account
# ----------------------------------------------------------------------------
if 1>&2 nsc describe account ${ACCOUNT_NAME} &> /dev/null; then
    echo_stderr "Account ${ACCOUNT_NAME} already exists."
else
    echo_stderr "Creating new account ${ACCOUNT_NAME}..."

    1>&2 nsc add account -n ${ACCOUNT_NAME}
    1>&2 nsc edit account ${ACCOUNT_NAME} --sk generate
    1>&2 nsc edit account -n ${ACCOUNT_NAME} \
        --allow-pub '>' \
        --allow-sub '>' \
        --js-mem-storage 128M \
        --js-disk-storage 256M  \
        --js-streams 10 \
        --js-consumer 100
fi

1>&2 nsc select account ${ACCOUNT_NAME}
echo_stderr "Selected account ${ACCOUNT_NAME}"

# ----------------------------------------------------------------------------
# Import the local account into the target NATS server
# ----------------------------------------------------------------------------
echo_stderr "Importing local account ${ACCOUNT_NAME} into NATS keystore..."
nsc describe account ${ACCOUNT_NAME} --raw --output-file pubkey-account-jwt.tmp

1>&2 ${CONTAINER_CLI} cp pubkey-account-jwt.tmp ${NSC_CONTAINER}:/tmp/import.jwt
1>&2 ${CONTAINER_CLI} exec -it ${NSC_CONTAINER} nsc import account --file /tmp/import.jwt --force --overwrite 
1>&2 ${CONTAINER_CLI} exec -it ${NSC_CONTAINER} nsc push -A

1>&2 ${CONTAINER_CLI} exec -it ${NSC_CONTAINER} rm -f /tmp/import.jwt
rm -f pubkey-account-jwt.tmp

1>&2 ${CONTAINER_CLI} exec -it ${NATS_CONTAINER} nats-server --signal reload

echo_stderr "Account ${ACCOUNT_NAME} imported successfully."

# ----------------------------------------------------------------------------
# Create a local user
# ----------------------------------------------------------------------------
echo_stderr "Creating new user ${USER_NAME} for account ${ACCOUNT_NAME}..."

1>&2 nsc add user -a ${ACCOUNT_NAME} -n ${USER_NAME} --allow-pubsub '>' || echo_stderr "User ${USER_NAME} already exists."
nsc generate creds --account ${ACCOUNT_NAME} --name ${USER_NAME}

1>&2 nats context save ${ACCOUNT_NAME}-${USER_NAME} --nsc=nsc://${OPERATOR_NAME}/${ACCOUNT_NAME}/${USER_NAME} -s ${NATS_URL} --select


# ----------------------------------------------------------------------------
# Quick test of the new user credentials
# ----------------------------------------------------------------------------
echo_stderr Sanity test...
1>&2 nats sub test.${ACCOUNT_NAME}.${USER_NAME} &
1>&2 nats pub test.${ACCOUNT_NAME}.${USER_NAME} my-test-item-01

