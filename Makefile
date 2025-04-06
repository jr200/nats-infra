TEAM_NAME:=infra-team
OPERATOR_NAME:=local-operator

all: down up

config-networks:
	podman network create -d bridge --ignore --internal infra-public

up: config-networks
	podman compose -f compose-infra.yaml -p ${TEAM_NAME} up -d

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
