# NixOSホストでのデプロイ(flake)

最終更新: 2026-08-16

Debian以外にNixOSをホストにする場合、[../flake.nix](../flake.nix) と
[../nixos/pve-podman.nix](../nixos/pve-podman.nix) でホスト設定(Podman有効化・
`/dev/fuse`用カーネルモジュール・ファイアウォール・macvlanネットワーク作成)と
コンテナのデプロイ(`virtualisation.oci-containers`)を宣言的に管理できる。

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
を参照。macvlanホストシムは[前述の決定](SPEC.md)により対象外としているため、
このモジュールには含まれていない。

macvlanのカーネル制約上、シムがない場合は**Podmanホスト自身のOSから**
`https://<PVE_IP>:8006` に直接アクセスすることができない(同じLAN上の
他の端末からは通常どおりアクセスできる)。ホスト自身からのアクセスが
必要になった場合は、`networking.macvlans` などでシムIFを追加する対応を
別途検討すること。

## configuration.nix側で設定・追加すべきこと

`nixos/pve-podman.nix` はPodman/コンテナ/macvlanネットワーク作成のみを担当する。
以下はモジュールがカバーしないため、ホスト側の `configuration.nix`
(または相当するflakeモジュール)で別途設定する必要がある。

- **flakes有効化**: `nixos-rebuild switch --flake` を使うには
  `nix.settings.experimental-features = [ "nix-command" "flakes" ];`
  が必要(NixOS標準インストールではデフォルト無効)。
- **ホスト自身のネットワークインターフェース設定**: `services.pvePodman.parentIface`
  で指定する物理NICに、ホストOS自身のIP(LAN上の到達可能なアドレス)を
  割り当てておくこと。macvlanは既存の物理NIC設定の上に「乗る」形なので、
  NIC自体がリンクアップしてLANに接続されている状態が前提(DHCPでもstaticでも可)。
  この設定自体は本モジュールの対象外。
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
- **(impermanence構成を使う場合)永続化パス**: rootを `tmpfs` にする構成では、
  Podmanのボリューム置き場(既定 `/var/lib/containers`)を永続データセット側に
  含めること。含めないとホスト再起動でVMディスク・pve-cluster設定が消える。

## 検証状況

2026-08-16時点、`nix flake check` と、ダミー設定での `nixosSystem` 評価
(`system.build.toplevel` 導出)まではこのマシン上で確認済み。実際のNixOS実機での
`nixos-rebuild switch` 適用確認は、[SPEC.md](SPEC.md) 6節の他の未解決事項と同様に
後日実機作業で行う(詳細は [SPEC.md](SPEC.md) 8節参照)。
