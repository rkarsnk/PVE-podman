#!/usr/bin/env bash
#
# setup-bridge.sh
#
# Podmanホスト側で、物理NICをポートとするLinuxブリッジを作成し、
# その上にPVEコンテナ用のPodman bridgeネットワーク(unmanagedモード)を作成する。
#
# macvlan(既定のbridgeモード)は宛先MACアドレスをmacvlan子IFごとに
# ハッシュ照合してフィルタするため、PVEコンテナ内でさらに vmbr0 が
# ブリッジするVM/ネストしたLXCのMAC宛フレームが転送されない
# (doc/SPEC.md 参照)。本物のLinuxブリッジにはそのフィルタが存在しないため、
# この問題が起きない。副次効果として、macvlanと違いホスト自身から
# PVEコンテナへも直接到達できる。
#
# 注意: この処理は物理NICをブリッジに「移設」する(NIC自体からはIPが
# 外れる)。ホスト自身のIPは物理NICではなくブリッジ側に設定し直す必要が
# あるが、その設定方法はホストのネットワーク管理方式(ifupdown/
# systemd-networkd/NetworkManager等)に依存するため本スクリプトでは
# 行わない。SSH等でリモート接続している場合、この移設のタイミングで
# 接続が切れる可能性があるため、コンソールアクセスがある状態で
# 作業すること。
#
# 環境変数:
#   PARENT_IFACE   ブリッジのポートにする物理NIC名 (既定: eth0)
#   BRIDGE_NAME    作成するホスト側Linuxブリッジ名 (既定: br-pve)
#   SUBNET         VM/PVEコンテナが属するLANのサブネット (既定: 192.168.1.0/24)
#   GATEWAY        そのLANのデフォルトゲートウェイ (既定: 192.168.1.1)
#   NETWORK_NAME   作成するPodmanネットワーク名 (既定: pve-bridge)
#
# 使用例:
#   PARENT_IFACE=eth0 SUBNET=192.168.1.0/24 GATEWAY=192.168.1.1 \
#     ./host/setup-bridge.sh

set -Eeuo pipefail

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }

: "${PARENT_IFACE:="eth0"}"
: "${BRIDGE_NAME:="br-pve"}"
: "${SUBNET:="192.168.1.0/24"}"
: "${GATEWAY:="192.168.1.1"}"
: "${NETWORK_NAME:="pve-bridge"}"

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

if ip link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
  info "Bridge '${BRIDGE_NAME}' already exists, skipping creation."
else
  info "Creating host bridge '${BRIDGE_NAME}' with ${PARENT_IFACE} as a port..."
  ip link add "${BRIDGE_NAME}" type bridge
  ip link set "${PARENT_IFACE}" master "${BRIDGE_NAME}"
  ip link set "${PARENT_IFACE}" up
  ip link set "${BRIDGE_NAME}" up
  info "Note: this bridge is not persistent across reboots. Add it to your"
  info "network configuration (e.g. systemd-networkd, /etc/network/interfaces)"
  info "if you need it to survive a host reboot, and move this host's own"
  info "IP address from ${PARENT_IFACE} to ${BRIDGE_NAME} there."
fi

if podman network exists "${NETWORK_NAME}" 2>/dev/null; then
  info "Podman network '${NETWORK_NAME}' already exists, skipping creation."
else
  info "Creating podman bridge network '${NETWORK_NAME}' on ${BRIDGE_NAME} (${SUBNET})..."
  podman network create -d bridge \
    -o mode=unmanaged \
    --interface-name "${BRIDGE_NAME}" \
    --subnet "${SUBNET}" \
    --gateway "${GATEWAY}" \
    "${NETWORK_NAME}"
fi

echo
info "Done. Run the PVE container with:"
echo "    --network ${NETWORK_NAME} --ip <container-ip-within-${SUBNET}>"
