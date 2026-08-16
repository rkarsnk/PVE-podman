# 仕様書: Podman上でのProxmox VE(コンテナ版)構築

最終更新: 2026-08-16
引き継ぎ先: Claude Code

## 1. 背景と目的

Debian 13ホスト上で、Proxmox VE(PVE)のWeb UI/CLIを使ってVM(KVM)を管理したい。
ただしPVEを裸のLXCコンテナに入れるのは技術的に無理があると判断し、
[dockur/proxmox](https://github.com/dockur/proxmox) が採用している
「Debian 13 + proxmox-veパッケージをOCIコンテナイメージ化する」手法を、
Docker前提の実装からPodman + macvlan前提に作り替える。

## 2. 決定事項

1. **ランタイム**: Podman(rootful必須。理由は7参照)
2. **KVM**: ホストのKVMを `/dev/kvm` デバイスパススルーで直接使用。ネスト仮想化は使わない。
3. **LXCコンテナ管理**: 今回のスコープ外。PVEのLXC管理機能そのものは無効化しないが、
   別ツール(Incus等)による統合管理は行わない。
4. **pve-kernel**: `proxmox-ve` メタパッケージの `Depends` として引き込まれるため、
   インストール自体は回避しない。インストール中の副作用(ブートローダー操作)を
   コマンドスタブで無害化し、インストール完了後にカーネル本体を削除する
   (dockur/proxmox方式を踏襲。詳細は `Dockerfile` のコメント参照)。
5. **ネットワーク**: Podmanのmacvlanネットワークでコンテナ自体にLAN直結のIPを付与し、
   コンテナ内で `vmbr0` がmacvlan経由の `eth0` を「物理NIC相当」としてブリッジする。
   dockur/proxmox標準のNAT機構(`network.sh` の `configureNAT`)は
   環境変数 `NETWORK=N` で無効化し、代わりに独自スクリプト
   `generate-interfaces.sh` で `/etc/network/interfaces` を生成する。
6. **ストレージ**: LVM/ZFS/Cephは使用しない。ディレクトリベースストレージのみ。
7. **systemd**: rootful Podmanで `--systemd=always` を指定し、PID1をsystemd
   (`/sbin/init`)にする。cgroup委譲や `/run`, `/tmp` のtmpfs自動設定を
   Podmanに任せるため、rootless運用は本仕様の対象外とする。
8. **マイグレーション**: VMディスクは `/var/lib/vz`、クラスタ設定は
   `/var/lib/pve-cluster` にボリュームとして永続化し、ホスト入れ替え時は
   ボリューム単位でのエクスポート/インポートを前提とする。

## 3. アーキテクチャ

```text
LAN (例: 192.168.1.0/24)
   │
   ├─ Podmanホスト (Debian 13, 物理NIC eth0)
   │     │
   │     ├─ /dev/kvm ──パススルー──▶ PVEコンテナ
   │     │
   │     └─ macvlanネットワーク "pve-macvlan" (parent=eth0)
   │           │
   │           └─ PVEコンテナ (--network pve-macvlan --ip 192.168.1.50)
   │                 └─ vmbr0 (macvlan eth0 をブリッジポートに)
   │                       ├─ VM1 (tapX, LAN直結IP)
   │                       └─ VM2 (tapY, LAN直結IP)
```

## 4. 検討して除外した選択肢(参考・経緯)

- **PVEをLXCコンテナに直接インストール**: pve-kernel・KVMネスト・物理ブリッジ制御・
  systemd/cgroupの整合性問題が大きく断念。Podman/Dockerコンテナ方式に変更したことで
  カーネルとsystemdの問題は解消。ネットワークはNAT方式(dockur標準)ではなくmacvlan方式を選択。
- **Incusによるホスト直接のLXC/VM統合管理**: 別案として検討したが、
  「PVEのWeb UIをそのまま使いたい」という要求を優先し保留。
- **二重ネスト構成(コンテナの中にさらにIncus等を入れる)**: 将来のホスト移行性が
  悪化するため不採用。ホスト直接構成に回帰。

## 5. 決定済み(2026-08-16 追記・1巡目)

1. **macvlanホストシム**: 不要と確定。PVE Web UIへはLAN内の別端末からアクセスする
   運用とし、Podmanホスト自身からの到達性は要件としない。`host/setup-macvlan.sh` の
   `CREATE_HOST_SHIM` はデフォルト`N`のまま使用し、この機能は当面使わない
   (将来必要になった場合のみ再検討)。
2. **rootful固定**: 確定。rootless案は不採用とし、`--privileged` +
   `--systemd=always` のrootful運用で進める(決定事項1・7の通り)。

## 6. 未解決・要検証事項(実機での検証が必要)

1. **ビルド時のネットワーク到達性**: `Dockerfile` 内で
   `enterprise.proxmox.com`, `download.proxmox.com`, GitHub(`pve-fake-subscription`の
   リリースアセット)へのアクセスが必要。2026-08-16、手元のcolima(arm64ネイティブ、
   BuildKit)で `docker build` を実行し到達性・`proxmox-ve`一式のインストールまで
   完走を確認済み(補足: `proxmox-ve`本体・`pve-manager`・`qemu-server`・
   `proxmox-kernel`等の依存パッケージはarm64向けにも配布されている。当初
   「amd64限定」と誤認していたが実際にはarm64も提供されている)。
   Podman実機(Intel)での最終確認は後日実機作業時に行う(保留)。
2. **pve-cluster (pmxcfs) の単一ノード動作確認**: `/dev/fuse` パススルーと
   `--systemd=always` のcgroup委譲設定で `pve-cluster.service` が正常起動するかは
   実機検証が必要。2026-08-16、colima(arm64ネイティブ)上で
   `docker run --privileged`(macvlanは省略しdocker0ブリッジで代用、
   `REQUIRE_KVM=N`)にて起動確認。`systemctl is-system-running` は `running`、
   `pve-cluster.service`(pmxcfs)・`pveproxy.service`・`pvedaemon.service`は
   いずれも正常起動、`systemctl --failed` は0件、コンテナ内・Dockerヘルスチェック
   経由の両方でWeb UI(`https://localhost:8006`)のHTML応答も確認済み。
   ただしこの検証はmacvlanネットワークと`/dev/kvm`パススルーを含んでおらず、
   Podman + macvlan + KVMパススルーの組み合わせでの最終確認は
   後日実機(Intel)作業時に行う(保留)。

## 7. 決定済み(2026-08-16 追記・2巡目)

1. **バックアップ/マイグレーション手順**: スクリプト化はせず、手順書(マニュアル)を
   `doc/BACKUP.md` として整備する。
2. **VMディスク形式**: qcow2で確定。

## 8. 提供ファイル一覧

```text
pve-podman/
├── SPEC.md                     # 本ファイル
├── BACKUP.md                   # 新規: バックアップ/マイグレーション手順書
├── Dockerfile                  # dockur/proxmox をベースに ENTRYPOINT を差し替え
├── src/
│   ├── entrypoint.sh            # dockur/proxmox オリジナル(無改造)
│   ├── network.sh               # dockur/proxmox オリジナル(無改造。NETWORK=Nで無効化して使う)
│   ├── generate-interfaces.sh   # 新規: 環境変数からmacvlan構成のinterfacesを生成
│   └── entrypoint-wrapper.sh    # 新規: generate-interfaces.sh実行後、entrypoint.shへexec
└── host/
    └── setup-macvlan.sh         # 新規: Podmanホスト側でmacvlanネットワークを作成
```

`src/entrypoint.sh` と `src/network.sh` は
<https://github.com/dockur/proxmox> (`src/entrypoint.sh`, `src/network.sh`) から
そのまま取得したものであり、改造していない。`network.sh` は環境変数
`NETWORK=N` を渡すことで、末尾の `disabled "$NETWORK" && return 0` により
NAT構成処理(`configureNAT`)がスキップされる仕組みになっている。

## 9. コンテナ実行時の環境変数

| 変数 | 必須 | 既定値 | 説明 |
| - | - | - | - |
| `PVE_IFACE` | いいえ | `eth0` | `vmbr0` にブリッジするNIC名(macvlanで払い出されるIF) |
| `PVE_IP` | **はい** | - | PVEホストの静的IP |
| `PVE_PREFIX` | いいえ | `24` | サブネットのプレフィックス長 |
| `PVE_GATEWAY` | **はい** | - | デフォルトゲートウェイ |
| `PVE_DNS` | いいえ | - | スペース区切りのDNSサーバー一覧 |
| `NETWORK` | **はい(`N`固定)** | - | dockur標準のNAT機構を無効化するため必ず `N` を指定 |
| `REQUIRE_KVM` | いいえ | `Y` | `/dev/kvm` の必須チェック有無 |
| `REQUIRE_FUSE` | いいえ | `Y` | `/dev/fuse` の必須チェック有無(pmxcfsに必要) |
| `PASSWORD` | いいえ | `root` | rootパスワード |

## 10. 実行コマンド例

```bash
# 1. ホスト側でmacvlanネットワークを準備
PARENT_IFACE=eth0 SUBNET=192.168.1.0/24 GATEWAY=192.168.1.1 \
  ./host/setup-macvlan.sh

# 2. イメージをビルド
podman build -t pve-podman:latest .

# 3. コンテナを起動
podman run -d \
  --name pve \
  --systemd=always \
  --privileged \
  --network pve-macvlan --ip 192.168.1.50 \
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

## 11. 参考

- <https://github.com/dockur/proxmox> — Dockerfile / entrypoint.sh / network.sh のベース実装
