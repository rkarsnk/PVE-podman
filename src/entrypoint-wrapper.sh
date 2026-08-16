#!/usr/bin/env bash
#
# entrypoint-wrapper.sh
#
# Dockerfile の ENTRYPOINT はこのスクリプトを指す(entrypoint.sh を直接は指さない)。
# systemd (PID1) が /etc/network/interfaces を読んで networking.service を
# 起動する前に、macvlan向けの静的IP設定を書き出しておく必要があるため、
# generate-interfaces.sh を先に実行してから、
# 本来の entrypoint.sh (dockur/proxmox オリジナル、無改造) へ exec する。
#
# entrypoint.sh の中で network.sh が source されるが、NETWORK=N を
# 渡している前提なので configureNAT() 側は何もしない
# (このラッパーが書いた /etc/network/interfaces を上書きしない)。

set -Eeuo pipefail

/usr/local/bin/generate-interfaces.sh

exec /usr/local/bin/entrypoint.sh "$@"
