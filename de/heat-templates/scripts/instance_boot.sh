#!/bin/bash
set -x

DOCKER_DEFAULT_ADDRESS_POOL=${DOCKER_DEFAULT_ADDRESS_POOL:-10.10.1.0/16}
# DOCKER_DEFAULT_ADDRESS_SIZE have to be less then netmask in DOCKER_DEFAULT_ADDRESS_POOL because
# to the fact that actual netmask for docker_gwbridge is given from it
DOCKER_DEFAULT_ADDRESS_SIZE=${DOCKER_DEFAULT_ADDRESS_SIZE:-24}
HOST_INTERFACE=${HOST_INTERFACE:-ens3}
NODE_IP_ADDRESS=$(ip addr show dev ${HOST_INTERFACE} |grep -Po 'inet \K[\d.]+' |egrep -v "127.0.|172.17")
UCP_USERNAME=${UCP_USERNAME:-admin}
UCP_PASSWORD=${UCP_PASSWORD:-administrator}
OS_CODENAME=$(lsb_release -c -s)
KUBECTL_VERSION=${KUBECTL_VERSION:-v1.14.0}
NODE_DEPLOYMENT_RETRIES=${NODE_DEPLOYMENT_RETRIES:-15}
FLOATING_NETWORK_PREFIXES=${FLOATING_NETWORK_PREFIXES:-10.11.12.0/24}
PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-ens4}
PUBLIC_NODE_IP_ADDRESS=$(ip addr show dev ${PUBLIC_INTERFACE} | grep -Po 'inet \K[\d.]+' | egrep -v "127.0.|172.17")
PUBLIC_NODE_IP_NETMASK=$(ip addr show dev ${PUBLIC_INTERFACE} | grep -Po 'inet \K[\d.]+\/[\d]+' | egrep -v "127.0.|172.17" | cut -d'/' -f2)

NODE_TYPE=$node_type
UCP_MASTER_HOST=$ucp_master_host
UCP_MASTER_HOST=${UCP_MASTER_HOST:-${NODE_IP_ADDRESS}}
NODE_METADATA='$node_metadata'

function retry {
    local retries=$1
    shift
    local msg="$1"
    shift

    local count=0
    until "$@"; do
        exit=$?
        wait=$((2 ** $count))
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left."
            echo "$msg"
            return $exit
        fi
    done
    return 0
}

function wait_condition_send {
    local status=${1:-SUCCESS}
    local reason=${2:-empty}
    local data_binary="{\"status\": \"$status\", \"reason\": \"$reason\"}"
    echo "Trying to send signal to wait condition 5 times: $data_binary"
    WAIT_CONDITION_NOTIFY_EXIT_CODE=2
    i=0
    while (( ${WAIT_CONDITION_NOTIFY_EXIT_CODE} != 0 && ${i} < 5 )); do
        $wait_condition_notify -k --data-binary "$data_binary" && WAIT_CONDITION_NOTIFY_EXIT_CODE=0 || WAIT_CONDITION_NOTIFY_EXIT_CODE=2
        i=$((i + 1))
        sleep 1
    done
    if (( ${WAIT_CONDITION_NOTIFY_EXIT_CODE} !=0 && "${status}" == "SUCCESS" ))
    then
        status="FAILURE"
        reason="Can't reach metadata service to report about SUCCESS."
    fi
    if [ "$status" == "FAILURE" ]; then
        exit 1
    fi
}

function install_docker_ce {
    function install_retry {
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl --retry 6 --retry-delay 5 -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable"
        apt update
        apt install -y docker-ce jq unzip
    }
    retry 10 "Failed to install docker CE" install_retry
}

function update_docker_network {
    mkdir -p /etc/docker
    cat <<EOF > /etc/docker/daemon.json
{
  "default-address-pools": [
    { "base": "${DOCKER_DEFAULT_ADDRESS_POOL}", "size": ${DOCKER_DEFAULT_ADDRESS_SIZE} }
  ]
}
EOF

}

function install_ucp {
    local tmpd
    tmpd=$(mktemp -d)
    cat <<EOF > ${tmpd}/docker_subscription.lic
$ucp_license_key
EOF

    docker container run --rm --name ucp \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $tmpd/docker_subscription.lic:/config/docker_subscription.lic \
    docker/ucp:3.2.4 install \
    --host-address $NODE_IP_ADDRESS \
    --admin-username $UCP_USERNAME \
    --admin-password $UCP_PASSWORD \
    --existing-config
}

function download_bundles {
    local tmpd
    tmpd=$(mktemp -d)

    function download_bundles_retry {
    # Download the client certificate bundle
        curl -k -H "Authorization: Bearer $AUTHTOKEN" https://${UCP_MASTER_HOST}/api/clientbundle -o ${tmpd}/bundle.zip
    }
    # Download the bundle https://docs.docker.com/ee/ucp/user-access/cli/
    # Create an environment variable with the user security token
    AUTHTOKEN=$(curl -sk -d '{"username":"'$UCP_USERNAME'","password":"'$UCP_PASSWORD'"}' https://${UCP_MASTER_HOST}/auth/login | jq -r .auth_token)

    retry 3 "Can't download bundle file from master." download_bundles_retry

    pushd $tmpd
    # Unzip the bundle.
    unzip bundle.zip

    # Run the utility script.
    eval "$(<env.sh)"
    mkdir -p /etc/kubernetes /root/.kube/
    cp kube.yml /etc/kubernetes/admin.conf
    cp kube.yml /root/.kube/config
    popd
}

function wait_for_node {
    function retry_wait {
        kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes |awk '{print $1}' |grep -q $(hostname)
    }
    retry $NODE_DEPLOYMENT_RETRIES "The node didn't come up." retry_wait
}


function join_node {
    env -i $(docker swarm join-token $1 |grep 'docker swarm join' | xargs)
}

function create_ucp_config {
    echo "
[scheduling_configuration]
    enable_admin_ucp_scheduling = true
    default_node_orchestrator = \"kubernetes\"
[cluster_config]
    dns = [\"172.18.208.44\"]
" | docker config create com.docker.ucp.config -
}

function swarm_init {
    docker swarm init --advertise-addr ${HOST_INTERFACE}
}

function rm_ucp_config {
    docker config rm com.docker.ucp.config
}

function install_kubectl {
    curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl
    chmod +x kubectl
    mv kubectl /usr/local/bin/
}

function prepare_network {
    systemctl restart systemd-resolved
    # Make sure local hostname is present in /etc/hosts
    sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost\n${NODE_IP_ADDRESS} $(hostname)/" /etc/hosts
}

function workaround_default_forward_policy {
    for net in $FLOATING_NETWORK_PREFIXES; do
        iptables -I DOCKER-USER  -d ${net} -j ACCEPT
        iptables -I DOCKER-USER  -s ${net} -j ACCEPT
    done
}

function configure_public_interface {
    local public_interface=${1:-${PUBLIC_INTERFACE}}
    local cloud_netplan_cfg="/etc/netplan/50-cloud-init.yaml"
    local match_ip_line

    DEBIAN_FRONTEND=noninteractive apt -y install bridge-utils atop

cat << EOF > /etc/systemd/network/10-veth-phy-br.netdev
[NetDev]
Name=veth-phy
Kind=veth
[Peer]
Name=veth-br
EOF
    sed -i 's/.*ethernets:.*/&\n        veth-phy: {}/' ${cloud_netplan_cfg}
    sed -i 's/.*ethernets:.*/&\n        veth-br: {}/' ${cloud_netplan_cfg}

    match_ip_line=$(grep -nm1 "${PUBLIC_NODE_IP_ADDRESS}/${PUBLIC_NODE_IP_NETMASK}" ${cloud_netplan_cfg} | cut -d: -f1)

    sed -i "$((${match_ip_line}-1)),$((${match_ip_line}))d" ${cloud_netplan_cfg}

cat << EOF >> ${cloud_netplan_cfg}
    bridges:
        br-public:
            dhcp4: false
            interfaces:
            - ${PUBLIC_INTERFACE}
            - veth-br
            addresses:
            - ${PUBLIC_NODE_IP_ADDRESS}/${PUBLIC_NODE_IP_NETMASK}
EOF
    netplan --debug apply
}

function set_node_labels {

    kubectl patch node $(hostname) -p "{\"metadata\": ${NODE_METADATA}}"
}

case "$NODE_TYPE" in
    ucp)
        prepare_network
        update_docker_network
        install_docker_ce
        configure_public_interface
        swarm_init
        create_ucp_config
        install_ucp
        download_bundles
        rm_ucp_config
        install_kubectl
        workaround_default_forward_policy
        wait_for_node
        set_node_labels
        ;;
    master)
        prepare_network
        update_docker_network
        install_docker_ce
        configure_public_interface
        download_bundles
        join_node manager
        install_kubectl
        workaround_default_forward_policy
        wait_for_node
        set_node_labels
        ;;
    worker)
        prepare_network
        update_docker_network
        install_docker_ce
        configure_public_interface
        download_bundles
        join_node worker
        install_kubectl
        workaround_default_forward_policy
        wait_for_node
        set_node_labels
        ;;
    *)
        echo "Usage: $0 {ucp|master|worker}"
        exit 1
esac


wait_condition_send "SUCCESS" "Instance successfuly started."
