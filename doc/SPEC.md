# 仕様書: Podman上でのProxmox VE(コンテナ版)構築

最終更新: 2026-08-16
引き継ぎ先: Claude Code

## 1. 背景と目的

Debian 13ホスト上で、Proxmox VE(PVE)のWeb UI/CLIを使ってVM(KVM)を管理したい。
ただしPVEを裸のLXCコンテナに入れるのは技術的に無理があると判断し、
[dockur/proxmox](https://github.com/dockur/proxmox) が採用している
「Debian 13 + proxmox-veパッケージをOCIコンテナイメージ化する」手法を、
Docker前提の実装からPodman前提に作り替える(ネットワークは当初macvlanを
検討したが、13節の理由によりホスト側Linuxブリッジ + Podman bridgeネットワーク
方式に変更した)。

## 2. 決定事項

1. **ランタイム**: Podman(rootful必須。理由は7参照)
2. **KVM**: ホストのKVMを `/dev/kvm` デバイスパススルーで直接使用。ネスト仮想化は使わない。
3. **LXCコンテナ管理**: 今回のスコープ外。PVEのLXC管理機能そのものは無効化しないが、
   別ツール(Incus等)による統合管理は行わない。
4. **pve-kernel**: `proxmox-ve` メタパッケージの `Depends` として引き込まれるため、
   インストール自体は回避しない。インストール中の副作用(ブートローダー操作)を
   コマンドスタブで無害化し、インストール完了後にカーネル本体を削除する
   (dockur/proxmox方式を踏襲。詳細は `Dockerfile` のコメント参照)。
5. **ネットワーク**: Podmanホスト側に物理NICをポートとするLinuxブリッジを作成し、
   その上にPodmanの `bridge` ネットワーク(`mode=unmanaged`)を重ねて
   コンテナ自体にLAN直結のIPを付与する。コンテナ内では `vmbr0` がそのveth
   (`eth0`)を「物理NIC相当」としてブリッジする(macvlanを不採用にした経緯は
   13節参照)。dockur/proxmox標準のNAT機構(`network.sh` の `configureNAT`)は
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
   ├─ Podmanホスト (Debian 13)
   │     │
   │     ├─ /dev/kvm ──パススルー──▶ PVEコンテナ
   │     │
   │     └─ ホスト側Linuxブリッジ "br-pve" (物理NIC eth0をポートに)
   │           │
   │           └─ Podman bridgeネットワーク "pve-bridge" (mode=unmanaged, br-pve上)
   │                 │
   │                 └─ PVEコンテナ (--network pve-bridge --ip 192.168.1.50, veth)
   │                       └─ vmbr0 (veth eth0 をブリッジポートに)
   │                             ├─ VM1 (tapX, LAN直結IP)
   │                             └─ VM2 (tapY, LAN直結IP)
```

macvlanではなく本物のLinuxブリッジを2段重ねる構成にしているのは、macvlan
(既定の`bridge`モード)は宛先MACアドレスをmacvlan子IFごとにハッシュ照合して
フィルタするため、コンテナ内 `vmbr0` がさらにブリッジするVM/ネストしたLXCの
MAC宛フレームが転送されない問題があるため(13節参照)。ホスト側ブリッジには
そのフィルタが存在せず、副次効果としてホスト自身からPVEコンテナへの
直接到達性も得られる。

## 4. 検討して除外した選択肢(参考・経緯)

- **PVEをLXCコンテナに直接インストール**: pve-kernel・KVMネスト・物理ブリッジ制御・
  systemd/cgroupの整合性問題が大きく断念。Podman/Dockerコンテナ方式に変更したことで
  カーネルとsystemdの問題は解消。ネットワークはNAT方式(dockur標準)ではなくmacvlan方式を選択。
- **Incusによるホスト直接のLXC/VM統合管理**: 別案として検討したが、
  「PVEのWeb UIをそのまま使いたい」という要求を優先し保留。
- **二重ネスト構成(コンテナの中にさらにIncus等を入れる)**: 将来のホスト移行性が
  悪化するため不採用。ホスト直接構成に回帰。

## 5. 決定済み(2026-08-16 追記・1巡目)

1. **macvlanホストシム**: 不要と確定していたが、13節の決定によりネットワーク方式を
   macvlanからホスト側Linuxブリッジ + Podman bridgeネットワークに変更したため、
   この論点自体が消滅した(本物のLinuxブリッジではmacvlan特有の
   親子間到達不可制約がなく、シムなしでもPodmanホスト自身からPVEコンテナへ
   直接到達できる)。
2. **rootful固定**: 確定。rootless案は不採用とし、`--privileged` +
   `--systemd=always` のrootful運用で進める(決定事項1・7の通り)。

## 6. 検証事項(実機確認済み)

1. **ビルド時のネットワーク到達性**: `Dockerfile` 内で
   `enterprise.proxmox.com`, `download.proxmox.com`, GitHub(`pve-fake-subscription`の
   リリースアセット)へのアクセスが必要。2026-08-16、手元のcolima(arm64ネイティブ、
   BuildKit)で `docker build` を実行し到達性・`proxmox-ve`一式のインストールまで
   完走を確認済み(補足: `proxmox-ve`本体・`pve-manager`・`qemu-server`・
   `proxmox-kernel`等の依存パッケージはarm64向けにも配布されている。当初
   「amd64限定」と誤認していたが実際にはarm64も提供されている)。
   2026-08-16、実機(NixOSホスト、Intel Core i5-10400、amd64)でも
   `podman build` の完走を確認済み。
2. **pve-cluster (pmxcfs) の単一ノード動作確認**: `/dev/fuse` パススルーと
   `--systemd=always` のcgroup委譲設定で `pve-cluster.service` が正常起動するかは
   実機検証が必要だった。2026-08-16、colima(arm64ネイティブ)上で
   `docker run --privileged`(macvlanは省略しdocker0ブリッジで代用、
   `REQUIRE_KVM=N`)にて起動確認。`systemctl is-system-running` は `running`、
   `pve-cluster.service`(pmxcfs)・`pveproxy.service`・`pvedaemon.service`は
   いずれも正常起動、`systemctl --failed` は0件、コンテナ内・Dockerヘルスチェック
   経由の両方でWeb UI(`https://localhost:8006`)のHTML応答も確認済み。
   その後2026-08-16、実機(NixOSホスト、Intel、`nixos/pve-podman.nix`経由で
   Podman + macvlan + `/dev/kvm`・`/dev/fuse`パススルーの完全な組み合わせ)でも
   同様に `systemctl is-system-running` は `running`、`pve-cluster.service`
   (pmxcfs)・`pveproxy.service`とも正常起動、`systemctl --failed` は0件、
   LAN内の別端末から `https://192.168.24.51:8006` へのアクセスでPVEログイン画面の
   HTML応答も確認済み。これにより本節の全項目の検証が完了した。
   **ただし、この検証はmacvlan方式時点のものである。13節でネットワーク方式を
   ホスト側Linuxブリッジ + Podman bridgeネットワークに変更したため、
   実機での再検証(特にネストしたVM/LXCのMAC宛フレーム転送)が別途必要。**

## 7. 決定済み(2026-08-16 追記・2巡目)

1. **バックアップ/マイグレーション手順**: スクリプト化はせず、手順書(マニュアル)を
   `doc/BACKUP.md` として整備する。
2. **VMディスク形式**: qcow2で確定。

## 8. NixOSホスト対応(2026-08-16 追記)

Debian 13以外にNixOSもホストOSとして許容する。ホスト設定(Podman有効化・
`/dev/fuse`用カーネルモジュール・ファイアウォール・ブリッジネットワーク作成)と
コンテナのデプロイ(`virtualisation.oci-containers`)を `flake.nix` /
`nixos/pve-podman.nix` で宣言的に管理できるようにした
(`host/setup-bridge.sh` 相当の処理はsystemd oneshotユニット+
`networking.bridges`として再実装。non-NixOSホスト向けにシェルスクリプトの方も残す)。
導入手順・検証状況・`hardware-configuration.nix`側で確認すべき項目は
[NIXOS.md](NIXOS.md) を参照。

## 9. 提供ファイル一覧

```text
pve-podman/
├── SPEC.md                     # 本ファイル
├── BACKUP.md                   # バックアップ/マイグレーション手順書
├── NIXOS.md                    # NixOSホストでのデプロイ手順(8節参照)
├── Dockerfile                  # dockur/proxmox をベースに ENTRYPOINT を差し替え
├── src/
│   ├── entrypoint.sh            # dockur/proxmox オリジナル(無改造)
│   ├── network.sh               # dockur/proxmox オリジナル(無改造。NETWORK=Nで無効化して使う)
│   ├── generate-interfaces.sh   # 環境変数からbridge構成のinterfacesを生成
│   └── entrypoint-wrapper.sh    # generate-interfaces.sh実行後、entrypoint.shへexec
├── host/
│   └── setup-bridge.sh          # Podmanホスト側でLinuxブリッジ+bridgeネットワークを作成(非NixOSホスト向け)
├── nixos/
│   └── pve-podman.nix           # NixOSモジュール(8節参照)
└── flake.nix                   # 上記モジュールを公開するflake
```

`src/entrypoint.sh` と `src/network.sh` は
<https://github.com/dockur/proxmox> (`src/entrypoint.sh`, `src/network.sh`) から
そのまま取得したものであり、改造していない。`network.sh` は環境変数
`NETWORK=N` を渡すことで、末尾の `disabled "$NETWORK" && return 0` により
NAT構成処理(`configureNAT`)がスキップされる仕組みになっている。

## 10. コンテナ実行時の環境変数

| 変数 | 必須 | 既定値 | 説明 |
| - | - | - | - |
| `PVE_IFACE` | いいえ | `eth0` | `vmbr0` にブリッジするNIC名(Podman bridgeネットワークで払い出されるveth) |
| `PVE_IP` | **はい** | - | PVEホストの静的IP |
| `PVE_PREFIX` | いいえ | `24` | サブネットのプレフィックス長 |
| `PVE_GATEWAY` | **はい** | - | デフォルトゲートウェイ |
| `PVE_DNS` | いいえ | - | スペース区切りのDNSサーバー一覧 |
| `NETWORK` | **はい(`N`固定)** | - | dockur標準のNAT機構を無効化するため必ず `N` を指定 |
| `REQUIRE_KVM` | いいえ | `Y` | `/dev/kvm` の必須チェック有無 |
| `REQUIRE_FUSE` | いいえ | `Y` | `/dev/fuse` の必須チェック有無(pmxcfsに必要) |
| `PASSWORD` | いいえ | `root` | rootパスワード |

## 11. 実行コマンド例

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
  -v /mnt/vm-images:/mnt/vm-images \
  -p 8006:8006 \
  pve-podman:latest
```

`-v /mnt/vm-images:/mnt/vm-images` のように、ホストの任意ディレクトリを
`-v <hostPath>:<containerPath>[:opts]` で追加バインドマウントできる。
`pve-var-lib-vz`/`pve-cluster` の名前付きボリュームとは別枠で、
`doc/BACKUP.md` のエクスポート/インポート対象にも含まれない。

## 12. 参考

- <https://github.com/dockur/proxmox> — Dockerfile / entrypoint.sh / network.sh のベース実装

## 13. ネットワーク方式の見直し: macvlan → ホストLinuxブリッジ(2026-08-16 追記・3巡目)

当初採用したmacvlan方式には、この構成に固有の問題があることが判明したため、
ホスト側Linuxブリッジ + Podman bridgeネットワーク方式に変更した。

1. **問題**: macvlan(既定の`bridge`モード)は、宛先MACアドレスを
   macvlan子IFごとにハッシュ照合してフィルタする実装になっている。
   物理NIC(macvlan作成に伴いpromiscuousになる)からmacvlanドライバへ
   渡された時点では全フレームが見えているが、そこから先、対応する
   macvlan子IFへ実際に配送されるかどうかは、そのフレームの宛先MACが
   その子IF自身(またはブロードキャスト/マルチキャスト)である場合に限られる。
   `generate-interfaces.sh` が行っている `ip link set eth0 promisc on`
   (macvlan子IF自体をpromiscuousにする)は、下位デバイス側の
   promiscuityを(既にpromiscuousな状態に対して重ねて)設定するだけで、
   macvlanドライバのこのMACハッシュ照合自体は解除しない。結果、
   PVEコンテナ内 `vmbr0` がブリッジするVM(tap)やネストしたLXCの
   MAC宛フレームは、macvlan子IF(コンテナの`eth0`)止まりのMACとは
   一致しないため配送されず、LANとの間で正しく転送されない。
2. **検討した代替案1: macvlan `passthru`モード**
   (`podman network create -d macvlan -o mode=passthru ...`)。
   このモードはMACベースのフィルタが存在せず、macvlan子IFが物理NICへの
   生アクセスを排他的に持つ扱いになるため、上記の転送問題自体は解決する。
   ただし「物理NIC1枚につきmacvlan子は1つまで」という制約があり、
   将来同じ物理NICを複数のPodmanコンテナで共有する構成に発展させる余地が
   なくなるため不採用とした。
3. **採用した代替案: ホスト側Linuxブリッジ + Podman `bridge`ネットワーク
   (`mode=unmanaged`)**。物理NICをポートとする本物のLinuxブリッジを
   ホスト側に作成し(`host/setup-bridge.sh` / NixOSでは
   `networking.bridges`)、その上にPodmanの`bridge`ドライバのネットワークを
   `mode=unmanaged`(Podmanによるブリッジの新規作成・NAT・ポートフォワードを
   行わせないモード)で重ねる。Linuxブリッジには前述のMACハッシュ照合の
   ような制約がなく、ネストしたVM/LXCのMAC宛フレームも正しく転送される。
   副次効果として、macvlan特有の「親(物理NIC)・子(macvlan)間は直接通信
   できない」というカーネル制約も存在しないため、Podmanホスト自身からも
   PVEコンテナへ直接到達できるようになった(5節1項の「macvlanホストシム」の
   論点はこれにより消滅)。また物理NIC1枚を複数コンテナで共有することも
   制約上可能(ただし本プロジェクトの現行スコープでは1NIC:1コンテナ構成の
   まま)。
4. **運用上の注意点**: ホスト自身のIP設定を、物理NIC単体からブリッジ
   インターフェース側へ移す必要がある(物理NICはブリッジのポートに
   徹し、IPを持たなくなるため)。この移設はホストのネットワーク管理方式に
   依存するため自動化しておらず、[NIXOS.md](NIXOS.md)・
   `host/setup-bridge.sh`のコメントで手順・注意点を案内するに留める。
   リモートホストに対してこの変更を適用する場合、移設のタイミングで
   接続が切れるリスクがあるため、コンソールアクセスがある状態での作業を
   推奨する。
5. **未検証事項**: この変更は2026-08-16時点でコード上の設計変更のみであり、
   実機での動作検証(特にPVEコンテナ内でVM/ネストしたLXCを起動し、
   LAN内の別端末からそのMACへのフレームが正しく往復することの確認)は
   まだ行っていない。6節の実機検証はmacvlan方式時点のものである点に注意。
