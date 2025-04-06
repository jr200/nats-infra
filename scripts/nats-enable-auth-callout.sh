#!/bin/bash

echo_stderr() { echo "$@" 1>&2; }

help() {
    cat << EOF 1>&2

This script enables the auth-callout feature on a local NATS account in a local development environment.
It then imports the updated account credentials *into* a running NATS server.

This script requires the following environment variables:

Required:
    OPERATOR_NAME       Name of the local NATS operator to create
    ACCOUNT_NAME        Name of the local+remote NATS account to create
    NATS_CONTAINER      Name of the container running the NATS server
    NSC_CONTAINER       Name of a container that can adminster credentials on the NATS server (requires nsc).

Optional:
    USER_NAME           Name of the user running the auth-callout micro-service (default: ac-user)
    USER_NAME_SENTINEL  Name of the sentinel user to direct to the auth-callout micro-service (default: nobody)
    OUTPUT_DIR          Output folder for credentials (default: .)
    NATS_URL            URL of the NATS server (default: nats://127.0.0.1:4222)
    CONTAINER_CLI       Container CLI to use, podman|docker|kubectl (default: podman)

Example:
    export OPERATOR_NAME=local-operator
    export ACCOUNT_NAME=MY-MINT
    export USER_NAME=ac-user
    export USER_NAME_SENTINEL=nobody
    export NATS_CONTAINER=nats-1
    export NSC_CONTAINER=nsc-admin-1
    export NATS_URL=nats://127.0.0.1:4222
    export CONTAINER_CLI=podman
EOF
}

# Set defaults if not provided
USER_NAME=${USER_NAME:-ac-user}
USER_NAME_SENTINEL=${USER_NAME_SENTINEL:-nobody}
NATS_URL=${NATS_URL:-nats://127.0.0.1:4222}
CONTAINER_CLI=${CONTAINER_CLI:-podman}
OUTPUT_DIR=${OUTPUT_DIR:-./nats-secrets}

# Validate required environment variables
if [ -z "$OPERATOR_NAME" ] || [ -z "$ACCOUNT_NAME" ] || \
   [ -z "$NATS_CONTAINER" ] || [ -z "$NSC_CONTAINER" ]; then
    echo_stderr "Error: Missing required environment variables"
    help
    exit 1
fi

mkdir -p ${OUTPUT_DIR}

# ----------------------------------------------------------------------------
# Select the local operator
# ----------------------------------------------------------------------------

if 1>&2 ! nsc describe operator ${OPERATOR_NAME} &> /dev/null; then
    echo_stderr "Operator ${OPERATOR_NAME} already exists."
    exit 1
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
if 1>&2 ! nsc describe account ${ACCOUNT_NAME} &> /dev/null; then
    echo_stderr "Account ${ACCOUNT_NAME} does not exist locally."
    exit 1
fi

1>&2 nsc select account ${ACCOUNT_NAME}
echo_stderr "Selected account ${ACCOUNT_NAME}"

# ----------------------------------------------------------------------------
# Configure the (account, user) for auth-callout usage
# ----------------------------------------------------------------------------

echo_stderr "Enabling auth-callout feature..."

if 1>&2 nsc describe user ${USER_NAME} &> /dev/null; then
    echo_stderr "User ${USER_NAME} already exists."
else
    echo_stderr "Creating new user ${USER_NAME}..."
    nsc add user --account ${ACCOUNT_NAME} --name ${USER_NAME}
fi

if 1>&2 nsc describe user ${USER_NAME_SENTINEL} &> /dev/null; then
    echo_stderr "Sentinel user ${USER_NAME_SENTINEL} already exists."
else
    echo_stderr "Creating new sentinel user ${USER_NAME_SENTINEL}..."
    nsc add user --account ${ACCOUNT_NAME} --name ${USER_NAME_SENTINEL}  --deny-pubsub ">" --bearer
fi

PUBKEY_USER_NAME=`nsc describe user --account ${ACCOUNT_NAME} --name ${USER_NAME} --field sub | jq -r`

nsc generate nkey --curve 2> ${OUTPUT_DIR}/${ACCOUNT_NAME}-enc.xk
PUBKEY_AUTH_CALLOUT_ENCRYPT=`sed -n 2,1p ${OUTPUT_DIR}/${ACCOUNT_NAME}-enc.xk`

nsc edit authcallout \
    --account ${ACCOUNT_NAME} \
    --auth-user ${PUBKEY_USER_NAME} \
    --allowed-account '*' \
    --curve ${PUBKEY_AUTH_CALLOUT_ENCRYPT}

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
# Saving credentials
# ----------------------------------------------------------------------------

function extract_signing_key() {
  local account=$1
  acct_sk=$(nsc describe account ${account} --json | jq -r '.nats.signing_keys[0]')
  nsc export keys --account ${account} --dir . --filter $acct_sk --force
  sk=$(cat ${acct_sk}.nk | tr -d '[:space:]')
  rm ${acct_sk}.nk
  echo -n $sk
}

echo_stderr "Writing signing key for ${ACCOUNT_NAME}"
extract_signing_key ${ACCOUNT_NAME} > ${OUTPUT_DIR}/${ACCOUNT_NAME}-sk-1.nk

echo_stderr "Writing user creds for ${USER_NAME}"
nsc generate creds --account ${ACCOUNT_NAME} --name ${USER_NAME} > ${OUTPUT_DIR}/${ACCOUNT_NAME}-${USER_NAME}.creds
nsc generate creds --account ${ACCOUNT_NAME} --name ${USER_NAME_SENTINEL} > ${OUTPUT_DIR}/${ACCOUNT_NAME}-${USER_NAME_SENTINEL}.creds
cat ${OUTPUT_DIR}/${ACCOUNT_NAME}-${USER_NAME_SENTINEL}.creds | base64 -w 0 | pbcopy

echo "Base64 sentinel user creds to clipboard"
