# PVE-podman

Podman上でProxmox VE(PVE)をコンテナとして動かすための構成一式。

詳細な設計判断は [doc/SPEC.md](doc/SPEC.md) を参照。

## 特徴

- Podman(rootful、`--systemd=always`)でPVEをコンテナ実行
- ホストのKVM(`/dev/kvm`)をパススルーし、コンテナ内でVMを直接稼働
- ホスト側Linuxブリッジ+Podman bridgeネットワークでコンテナにLAN直結IPを付与し、
  `vmbr0`経由でVMもLAN直結(macvlanを不採用にした経緯は[doc/SPEC.md](doc/SPEC.md) 13節参照)
- ストレージはディレクトリベースのみ(LVM/ZFS/Cephは非対応)

## ディレクトリ構成

```text
pve-podman/
├── Dockerfile                  # dockur/proxmox をベースに ENTRYPOINT を差し替え
├── src/
│   ├── entrypoint.sh            # dockur/proxmox オリジナル(無改造)
│   ├── network.sh               # dockur/proxmox オリジナル(無改造。NETWORK=Nで無効化して使う)
│   ├── generate-interfaces.sh   # 環境変数からbridge構成のinterfacesを生成
│   └── entrypoint-wrapper.sh    # generate-interfaces.sh実行後、entrypoint.shへexec
├── host/
│   └── setup-bridge.sh          # Podmanホスト側でLinuxブリッジ+bridgeネットワークを作成(非NixOSホスト向け)
├── nixos/
│   └── pve-podman.nix           # NixOSモジュール(ホスト設定+コンテナデプロイの宣言化)
├── flake.nix                    # 上記モジュールを公開するflake
└── doc/
    ├── SPEC.md                  # 仕様書・設計判断の記録
    ├── BACKUP.md                # バックアップ/マイグレーション手順書
    └── NIXOS.md                 # NixOSホストでのデプロイ手順(flake)
```

## セットアップ

```bash
# 1. ホスト側でLinuxブリッジ+bridgeネットワークを準備
PARENT_IFACE=eth0 SUBNET=192.168.1.0/24 GATEWAY=192.168.1.1 \
  ./host/setup-bridge.sh

# 2. イメージをビルド
podman build -t pve-podman:latest .

# 3. コンテナを起動
podman run -d \
  --name pve \
  --systemd=always \
  --privileged \
  --network pve-bridge --ip 192.168.1.50 \
  --device /dev/kvm \
  --device /dev/fuse \
  -e NETWORK=N \
  -e PVE_IP=192.168.1.50 \
  -e PVE_GATEWAY=192.168.1.1 \
  -e PVE_DNS="192.168.1.1" \
  -v pve-var-lib-vz:/var/lib/vz \
  -v pve-cluster:/var/lib/pve-cluster \
  -p 8006:8006 \
  pve-podman:latest
```

起動後、LAN内の別端末から `https://192.168.1.50:8006` でPVEのWeb UIにアクセスできる
(環境変数の詳細は [doc/SPEC.md](doc/SPEC.md) を参照)。

## NixOSホストでのデプロイ(flake)

Debian以外にNixOSをホストにする場合、[flake.nix](flake.nix) と
[nixos/pve-podman.nix](nixos/pve-podman.nix) でホスト設定とコンテナのデプロイを
宣言的に管理できる。導入例・`hardware-configuration.nix`側で確認すべき項目は
[doc/NIXOS.md](doc/NIXOS.md) を参照。

## 停止・破棄

### 停止(データは保持)

```bash
podman stop pve
```

再開する場合は `podman start pve`。ボリューム(`pve-var-lib-vz`, `pve-cluster`)は
そのまま残るため、VMディスクやクラスタ設定は失われない。

### 完全に破棄

```bash
# コンテナ削除
podman rm -f pve

# ボリューム削除(VMディスク・クラスタ設定も消える。事前にdoc/BACKUP.mdの手順で
# バックアップを取っていない場合、この操作で復元不能になる)
podman volume rm pve-var-lib-vz pve-cluster

# bridgeネットワーク削除(ホスト側Linuxブリッジ自体は別途 `ip link del br-pve` 等が必要)
podman network rm pve-bridge
```

ボリュームは削除せず、コンテナとネットワークだけ作り直したい場合は
`podman rm -f pve` と `podman network rm pve-bridge` のみ実行し、
ボリューム削除の手順は飛ばす。

## バックアップ / マイグレーション

ボリューム(`pve-var-lib-vz`, `pve-cluster`)のエクスポート/インポート手順は
[doc/BACKUP.md](doc/BACKUP.md) を参照。

## 検証状況

2026-08-16、arm64ネイティブ環境(colima)でのビルド・pmxcfs/pveproxy/pvedaemonの
起動確認に続き、実機(NixOSホスト、Intel)でもPodman + macvlan +
`/dev/kvm`・`/dev/fuse`パススルーの組み合わせでビルド・起動・Web UI応答まで
確認済み(詳細は [doc/SPEC.md](doc/SPEC.md) 6節、[doc/NIXOS.md](doc/NIXOS.md)
検証状況を参照)。**その後ネットワーク方式をmacvlanからホスト側Linuxブリッジ+
Podman bridgeネットワークに変更した([doc/SPEC.md](doc/SPEC.md) 13節)ため、
この新方式での実機再検証はまだ行っていない。**

## ライセンス

[MIT License](LICENSE)。

ベースとした [dockur/proxmox](https://github.com/dockur/proxmox)
もMIT Licenseで提供されている。`src/entrypoint.sh` と `src/network.sh` は
dockur/proxmoxからの無改造の取得物(詳細は [doc/SPEC.md](doc/SPEC.md) 8節参照)。

## Thanks

- [dockur/proxmox](https://github.com/dockur/proxmox)
  - Docker前提の実装をPodman前提に作り替えたもの.
