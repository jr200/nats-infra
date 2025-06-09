include .env.local

all: down up

config-networks:
	podman network create -d bridge --ignore --internal infra-public

init-nats: config-networks
	nats auth operator add --signing-key ${OPERATOR_NAME} || echo "Using existing operator."
	nsc select operator ${OPERATOR_NAME}
	nsc generate config --nats-resolver --sys-account SYSTEM | podman run --rm -i -v ${TEAM_NAME}_nats_config:/data busybox sh -c '[ -f /data/resolver.conf ] || cat > /data/resolver.conf'

up: 
	podman compose --env-file .env.local -f compose-infra.yaml -p ${TEAM_NAME} up -d

down:
	podman compose  -f compose-infra.yaml -p ${TEAM_NAME} down || echo "No running containers"

cleanup-nats: down
	podman volume rm -f ${TEAM_NAME}_nats_config
	podman volume rm -f ${TEAM_NAME}_nats_nsc_data
	podman volume rm -f ${TEAM_NAME}_nats_jetstream_data
	podman network rm infra-public -f
	rm -rf ~/.local/share/nats/nsc/stores/${OPERATOR_NAME}
	rm -rf ~/.local/share/nats/nsc/nkeys/${OPERATOR_NAME}
	mkdir -p ./tmp-keys
	nsc export keys --not-referenced --remove --dir ./tmp-keys || echo "No keys to remove"
	rm -rf ./tmp-keys
	@echo "Cleaned up"
