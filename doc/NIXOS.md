# NixOSホストでのデプロイ(flake)

最終更新: 2026-08-16

Debian以外にNixOSをホストにする場合、[../flake.nix](../flake.nix) と
[../nixos/pve-podman.nix](../nixos/pve-podman.nix) でホスト設定(Podman有効化・
`/dev/fuse`用カーネルモジュール・ファイアウォール・ホスト側Linuxブリッジ+
Podman bridgeネットワーク作成)とコンテナのデプロイ
(`virtualisation.oci-containers`)を宣言的に管理できる。

イメージのビルド(`podman build`)は、Debian/Proxmoxのaptリポジトリへの
ネットワークアクセスを伴うためNixの純粋ビルドの対象外とし、従来どおり
`podman build`(または `nix run .#build-image`)で用意しておく。

## 導入例

自分のNixOS構成に取り込む例:

```nix
{
  inputs.pve-podman.url = "git+https://<このリポジトリのURL>";

  outputs = { self, nixpkgs, pve-podman, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pve-podman.nixosModules.default
        {
          services.pvePodman = {
            enable = true;
            parentIface = "eth0";
            subnet = "192.168.1.0/24";
            gateway = "192.168.1.1";
            pveIp = "192.168.1.50";
            pveDns = "192.168.1.1";
            # ホストの任意ディレクトリを追加でバインドマウントしたい場合(任意)。
            extraVolumes = [ "/mnt/vm-images:/mnt/vm-images" ];
          };
        }
      ];
    };
  };
}
```

```bash
# イメージをビルド(このリポジトリ内で)
nix run .#build-image

# ホストに適用
sudo nixos-rebuild switch --flake .#myhost
```

`services.pvePodman` の全オプションは [../nixos/pve-podman.nix](../nixos/pve-podman.nix)
を参照。ネットワークは`parentIface`をポートとする`bridgeName`(既定 `br-pve`)
というホスト側Linuxブリッジをこのモジュールが宣言的に作成し、その上にPodmanの
`bridge`ネットワーク(`mode=unmanaged`)を重ねる方式になっている
([SPEC.md](SPEC.md) 13節)。macvlan方式時代は「ホスト自身から
PVEコンテナへ到達できない」という制約(macvlanシムがないと解決できない)が
あったが、本物のLinuxブリッジにはその制約がないため、**Podmanホスト自身の
OSからも** `https://<PVE_IP>:8006` に直接アクセスできる(同じLAN上の
他の端末からも通常どおりアクセスできる)。

## configuration.nix側で設定・追加すべきこと

`nixos/pve-podman.nix` はPodman/コンテナ/ブリッジ+bridgeネットワーク作成のみを
担当する。以下はモジュールがカバーしないため、ホスト側の `configuration.nix`
(または相当するflakeモジュール)で別途設定する必要がある。

- **flakes有効化**: `nixos-rebuild switch --flake` を使うには
  `nix.settings.experimental-features = [ "nix-command" "flakes" ];`
  が必要(NixOS標準インストールではデフォルト無効)。
- **ホスト自身のネットワークインターフェース設定(重要・破壊的変更あり)**:
  本モジュールは `services.pvePodman.parentIface` で指定した物理NICを
  `services.pvePodman.bridgeName`(既定 `br-pve`)というLinuxブリッジの
  ポートにする(`networking.bridges.${bridgeName}.interfaces = [ parentIface ]`)。
  これにより物理NIC自体はIPを持たなくなるため、**ホストOS自身のIP
  (LAN上の到達可能なアドレス、DHCPでもstaticでも可)は`parentIface`ではなく
  `bridgeName`側のインターフェースに設定し直す必要がある**
  (例: `networking.interfaces."br-pve".useDHCP = true;` や
  `networking.interfaces."br-pve".ipv4.addresses = [ ... ];`)。
  `parentIface`自身に`networking.interfaces`でIP/DHCP設定が残っていると
  ブリッジポートとしての動作やホストの到達性と競合するため、事前に外して
  おくこと。この設定変更をリモートホストに`nixos-rebuild switch --flake`で
  適用する場合、切り替えの一瞬でリンクが揺れて接続が切れる可能性があるため、
  可能であればコンソール(またはIPMI等の帯域外)アクセスがある状態で
  作業すること。この設定自体は本モジュールの対象外。
- **`system.stateVersion`**: 通常のNixOS構成同様、ホストの初回インストール時の
  リリースバージョンで固定しておくこと(本モジュールは設定しない)。
- **SSH等のリモート管理手段**: `nixos-rebuild switch --flake .#myhost` を
  リモートホストに対して実行する場合、`services.openssh.enable = true;` など
  リモートアクセス手段を別途有効化しておくこと。
- **(独自にnftables/iptablesルールを使う場合)ファイアウォールとの整合**:
  本モジュールは `networking.firewall.allowedTCPPorts` に `8006` を
  追加するだけ(`services.pvePodman.openFirewall = false` で無効化可)。
  `networking.nftables.enable` 等で独自ルールセットを使っている場合は、
  そちらにも同等の許可を追加すること。

## hardware-configuration.nix側で確認・追加すべきこと

`nixos/pve-podman.nix` はvirtualisation/ネットワーク周りのみを担当し、
ハードウェア依存の設定はホストの `hardware-configuration.nix`
(または個別の `configuration.nix`)側の責任にしている。以下を確認すること。

- **KVMカーネルモジュール**: `/dev/kvm` パススルーに必要。CPUに応じて
  `boot.kernelModules` に `"kvm-intel"`(Intel)または `"kvm-amd"`(AMD)を追加する。
  `nixos-generate-config` の出力に含まれていないことがあるので明示的に確認すること。
- **物理NIC名の確認**: `services.pvePodman.parentIface` に指定する値は、
  NixOSの予測可能ネットワークインターフェース名(`enp3s0` 等、`eth0` とは限らない)
  で実際のホストと一致している必要がある。`ip link` で確認する。
- **仮想化拡張の有効化**: BIOS/UEFI側でIntel VT-x/AMD-Vが有効になっていること
  (Nix設定ではなくファームウェア側の前提条件)。
- **(impermanence構成を使う場合のみ)永続化パス**: 「impermanence」
  (rootファイルシステムを`tmpfs`にして再起動ごとに初期化する構成パターン)を
  意識的に導入している場合のみ関係する項目。この構成では、Podmanのボリューム
  置き場(既定 `/var/lib/containers`)を永続データセット側に含めないと、
  ホスト再起動でVMディスク・pve-cluster設定が消える。
  対応方法はimpermanenceモジュールの `environment.persistence` で
  `/var/lib/containers` を指定するのが標準的(手動bind mountやPodmanの
  `graphroot`変更よりも推奨)。
  **通常インストールのNixOS(impermanenceを使っていない)なら、
  この項目は無視してよい**。ディスクは最初から永続化されている。

## 検証状況

2026-08-16、`nix flake check` と、ダミー設定での `nixosSystem` 評価
(`system.build.toplevel` 導出)を開発機上で確認した後、実機(NixOS 26.05、
Intel Core i5-10400、NIC `enp1s0`)でも一連の手順を実施し、以下を確認済み。

- ホスト設定をチャンネルベースの `configuration.nix` からflakeベース
  (別リポジトリ `nixos-config` を作成し `nixos-rebuild build/test/switch --flake`)
  に移行しても、SSH到達性等の既存動作に影響がないこと。
- `services.pvePodman` を導入した状態での `nixos-rebuild switch --flake` 適用が
  成功し、`podman-network-pve-macvlan.service`(macvlanネットワーク作成)・
  `podman-pve.service`(PVEコンテナ)がいずれも正常起動すること。
- `podman build` によるイメージビルドが実機(amd64ネイティブ)で完走すること。
- コンテナ内で `systemctl is-system-running` が `running`、
  `pve-cluster.service`(pmxcfs)・`pveproxy.service`が正常起動、
  `systemctl --failed` が0件であること。
- LAN内の別端末から `https://<PVE_IP>:8006` へアクセスし、PVEログイン画面の
  HTML応答が返ること(Podmanホスト自身からは前述のmacvlan制約により
  到達不可なのが期待通りであることも合わせて確認)。

これにより [SPEC.md](SPEC.md) 6節の実機検証事項はすべて解消した(**ただし
上記はmacvlan方式時点の検証結果である**)。

**2026-08-16追記・ネットワーク方式変更後の未検証事項**: [SPEC.md](SPEC.md) 13節の
理由により、ネットワーク方式をmacvlanからホスト側Linuxブリッジ+Podman
bridgeネットワーク(`mode=unmanaged`)に変更した。この変更は設計・コード上の
ものであり、以下はまだ実機で再検証していない。

- `services.pvePodman.bridgeName`(`networking.bridges`)経由でのブリッジ作成、
  および`podman-network-pve-bridge.service`の正常起動。
- ホストOS自身のIP設定を物理NICからブリッジ側へ移設した状態での、
  ホストの通常のLAN到達性(SSH等)に問題がないこと。
- PVEコンテナ内でVMまたはネストしたLXCを起動し、そのMACアドレス宛の
  フレームがLAN内の別端末との間で正しく往復すること(今回の方式変更の
  本来の目的)。
- Podmanホスト自身から `https://<PVE_IP>:8006` へ直接到達できること
  (macvlan時代の制約が解消されている想定の確認)。
