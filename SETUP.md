# NATS-Server Operating Guide

The guide assumes the existance of:

1. a desktop machine, for administering NATS operator, accounts, users.
2. a desktop machine running NATS-server in podman, for local development.
3. a kubernetes cluster running NATS-server, for deployments.

(1) and (2) can be the same machine.

This guide outlines how to:
- create/restore the operator.
- bootstrap two servers (one in kubernetes, one in docker)

## Create/Restore the Organisation's Operator

- the operator is _just an identity_ (i.e., it exists independently of any NATS-servers)
- a single operator's public-key can be used to bootstrap multiple NATS-servers
- (out of personal-preference, this guide will not share operators across NATS-servers).
- the operator's secret-keys are never loaded onto a NATS-server

```
OPERATOR_NAME=dev-operator
TEAM_NAME=infra-team

nats auth operator list
nats auth operator add $OPERATOR_NAME
```

The operator's secrets (nkeys) and SYSTEM account should be backed up and stored securely.
_note_: the `nats auth` cli has options to encrypt the json-payload.

```
nats auth operator backup $OPERATOR_NAME $OPERATOR_NAME-secret.json
```

## Bootstrap a local NATS-server using podman-compose

The `compose-infra.yaml` file launches these containers:
- nats-box (init-container)
- NATS-server
- (zitadel+zitadel-db - used later in the decentralised-auth section)


Configure the NATS-server's nats-resolver by creating a `resolver.conf` with the operator's public key and SYSTEM account's public key.

```
nsc select operator $OPERATOR_NAME

nsc generate config --nats-resolver --sys-account SYSTEM | podman run --rm -i -v ${TEAM_NAME}_nats_config:/data busybox sh -c '[ -f /data/resolver.conf ] || cat > /data/resolver.conf'
```

Start the NATS-server using `make up`.

Add a user `admin` under the `SYSTEM` account to monitor the cluster.
Create the credentials and context too.

```
nats auth user add admin SYSTEM
nats auth user ls SYSTEM

mkdir -p ~/.nats/saved-creds
SYSTEM_CREDS_FILE=~/.nats/saved-creds/${OPERATOR_NAME}-SYSTEM-admin.creds
nats auth user credential ${SYSTEM_CREDS_FILE} admin SYSTEM

# nsc push -u nats://127.0.0.1:4222
nats --server nats://127.0.0.1:4222 context add ${OPERATOR_NAME}-SYSTEM-admin --creds ${SYSTEM_CREDS_FILE} --description "SYSTEM-admin account" --select

nats server info
```

## Bootstrap a NATS-cluster in kubernetes

Generate a kubernetes `values.yaml` for the selected operator

```
nats auth operator select
nats server generate operator-values
```

Use the above in your helm chart deployment.
