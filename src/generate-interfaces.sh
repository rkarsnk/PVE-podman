#!/usr/bin/env bash
#
# generate-interfaces.sh
#
# entrypoint.sh (dockur/proxmox オリジナル) が source する network.sh は
# NETWORK=N を指定すると configureNAT() を実行せず、
# /etc/network/interfaces には一切手を触れない。
#
# このスクリプトはその代わりに、Podmanのbridgeネットワークで払い出された
# veth (既定 eth0) を「物理NIC相当」として vmbr0 にブリッジする
# /etc/network/interfaces を生成する。entrypoint-wrapper.sh から
# entrypoint.sh より先に呼ばれる想定。
#
# 環境変数:
#   PVE_IFACE   vmbr0にブリッジするNIC名 (既定: eth0)
#   PVE_IP      PVEホストの静的IP (必須)
#   PVE_PREFIX  サブネットのプレフィックス長 (既定: 24)
#   PVE_GATEWAY デフォルトゲートウェイ (必須)
#   PVE_DNS     スペース区切りのDNSサーバー一覧 (任意)

set -Eeuo pipefail

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }

: "${PVE_IFACE:="eth0"}"
: "${PVE_IP:=""}"
: "${PVE_PREFIX:="24"}"
: "${PVE_GATEWAY:=""}"
: "${PVE_DNS:=""}"

if [ -z "$PVE_IP" ]; then
  error "PVE_IP is required (static IP for the bridge interface)."
  exit 1
fi

if [ -z "$PVE_GATEWAY" ]; then
  error "PVE_GATEWAY is required (default gateway reachable via the bridge interface)."
  exit 1
fi

if [ ! -d "/sys/class/net/${PVE_IFACE}" ]; then
  error "Network interface '${PVE_IFACE}' does not exist inside the container."
  error "Check that the container was started with --network <bridge-network> and that PVE_IFACE matches the interface name Podman assigned."
  exit 1
fi

mkdir -p /etc/network

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

# ${PVE_IFACE} は Podman の bridge ネットワークで払い出された veth。
# ベアメタルPVEでいう「物理NIC」に相当するので、それ自体にはIPを振らず
# vmbr0 のブリッジポートとして使う。
auto ${PVE_IFACE}
iface ${PVE_IFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_IP}/${PVE_PREFIX}
    gateway ${PVE_GATEWAY}
    bridge-ports ${PVE_IFACE}
    bridge-stp off
    bridge-fd 0
    up ip link set ${PVE_IFACE} promisc on

source /etc/network/interfaces.d/*
EOF

if [ -n "$PVE_DNS" ]; then
  : > /etc/resolv.conf
  for ns in $PVE_DNS; do
    echo "nameserver $ns" >> /etc/resolv.conf
  done
fi

info "generate-interfaces: wrote /etc/network/interfaces (vmbr0 on ${PVE_IFACE}, ${PVE_IP}/${PVE_PREFIX}, gw ${PVE_GATEWAY})"

exit 0
