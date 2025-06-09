#!/bin/bash

echo_stderr() { echo "$@" 1>&2; }

help() {
    cat << EOF 1>&2

This script enables the auth-callout feature on a local NATS account in a local development environment.
It then imports the updated account credentials *into* a running NATS server.

This script requires the following environment variables:

Required:
    OPERATOR_NAME       Name of the local NATS operator to create
    ACCOUNT_NAME        The local account's signing key to fetch

Optional:
    OUTPUT_DIR          Output folder for credentials (default: ./nats-secrets)

Example:
    export OPERATOR_NAME=local-operator
    export ACCOUNT_NAME=MY-APP-1
    export OUTPUT_DIR=./nats-secrets

EOF
}

# Validate required environment variables
if [ -z "$OPERATOR_NAME" ] || [ -z "$ACCOUNT_NAME" ]; then
    echo_stderr "Error: Missing required environment variables"
    help
    exit 1
fi

# Set defaults if not provided
OUTPUT_DIR=${OUTPUT_DIR:-./nats-secrets}


function extract_signing_key() {
  local account=$1
  acct_sk=$(nsc describe account ${account} --json | jq -r '.nats.signing_keys[0]')
  1>&2 nsc export keys --account ${account} --dir . --filter $acct_sk --force
  KEY_FILE=${acct_sk}.nk
  if [ -f "${KEY_FILE}" ]; then
    sk=$(cat ${KEY_FILE} | tr -d '[:space:]')
    rm ${KEY_FILE}
    echo -n $sk
  else
    echo "!!! ERROR: KEY IS NOT STORED LOCALLY !!!"
  fi
}

mkdir -p ${OUTPUT_DIR}

echo_stderr "Fetching keys for account ${ACCOUNT_NAME}"

if nsc describe account -n ${ACCOUNT_NAME} &> /dev/null; then
    nsc describe account -n ${ACCOUNT_NAME} --json | jq -r .sub | tr -d '\n' > ${OUTPUT_DIR}/${ACCOUNT_NAME}-id-1.pub
    extract_signing_key ${ACCOUNT_NAME} > ${OUTPUT_DIR}/${ACCOUNT_NAME}-sk-1.nk
else
    echo_stderr "Account ${ACCOUNT_NAME} does not exist"
    exit 1
fi
