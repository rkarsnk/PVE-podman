#!/usr/bin/env bash
#
# setup-macvlan.sh
#
# Podmanホスト側で、PVEコンテナ用のmacvlanネットワークを作成する。
# macvlanの制約上、Podmanホスト自身はこのネットワークに割り当てられた
# コンテナのIPへ直接到達できない(macvlanの親/子インターフェースは
# 直接通信できないカーネル側の設計のため)。ホスト自身からPVEのWeb UIに
# アクセスする必要がある場合は CREATE_HOST_SHIM=Y を指定して
# ホスト側にもmacvlanのシムインターフェースを作成すること。
#
# 環境変数:
#   PARENT_IFACE      macvlanの親にする物理NIC名 (既定: eth0)
#   SUBNET            VM/PVEコンテナが属するLANのサブネット (既定: 192.168.1.0/24)
#   GATEWAY           そのLANのデフォルトゲートウェイ (既定: 192.168.1.1)
#   NETWORK_NAME      作成するPodmanネットワーク名 (既定: pve-macvlan)
#   CREATE_HOST_SHIM  Y にするとホスト側にもmacvlanシムIFを作る (既定: N)
#   SHIM_IP           シムIFに割り当てるIP (CREATE_HOST_SHIM=Y の場合必須)
#
# 使用例:
#   PARENT_IFACE=eth0 SUBNET=192.168.1.0/24 GATEWAY=192.168.1.1 \
#     ./host/setup-macvlan.sh
#
#   CREATE_HOST_SHIM=Y SHIM_IP=192.168.1.60 \
#   PARENT_IFACE=eth0 SUBNET=192.168.1.0/24 GATEWAY=192.168.1.1 \
#     ./host/setup-macvlan.sh

set -Eeuo pipefail

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }

: "${PARENT_IFACE:="eth0"}"
: "${SUBNET:="192.168.1.0/24"}"
: "${GATEWAY:="192.168.1.1"}"
: "${NETWORK_NAME:="pve-macvlan"}"
: "${CREATE_HOST_SHIM:="N"}"
: "${SHIM_IP:=""}"

if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root (sudo)."
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  error "podman command not found."
  exit 1
fi

if [ ! -d "/sys/class/net/${PARENT_IFACE}" ]; then
  error "Interface '${PARENT_IFACE}' does not exist on this host."
  exit 1
fi

if podman network exists "${NETWORK_NAME}" 2>/dev/null; then
  info "Podman network '${NETWORK_NAME}' already exists, skipping creation."
else
  info "Creating podman macvlan network '${NETWORK_NAME}' on ${PARENT_IFACE} (${SUBNET})..."
  podman network create -d macvlan \
    -o parent="${PARENT_IFACE}" \
    --subnet "${SUBNET}" \
    --gateway "${GATEWAY}" \
    "${NETWORK_NAME}"
fi

if [[ "${CREATE_HOST_SHIM^^}" == "Y" ]]; then

  if [ -z "$SHIM_IP" ]; then
    error "CREATE_HOST_SHIM=Y requires SHIM_IP to be set."
    exit 1
  fi

  if ip link show macvlan-shim >/dev/null 2>&1; then
    info "macvlan-shim already exists, skipping creation."
  else
    info "Creating host-side macvlan shim (macvlan-shim) at ${SHIM_IP}..."
    ip link add macvlan-shim link "${PARENT_IFACE}" type macvlan mode bridge
    ip addr add "${SHIM_IP}/32" dev macvlan-shim
    ip link set macvlan-shim up
    info "Note: this shim is not persistent across reboots. Add it to your"
    info "network configuration (e.g. systemd-networkd, /etc/network/interfaces)"
    info "if you need it to survive a host reboot."
  fi

fi

echo
info "Done. Run the PVE container with:"
echo "    --network ${NETWORK_NAME} --ip <container-ip-within-${SUBNET}>"
