# NixOSモジュール: Podman上でPVEコンテナをデプロイするホスト設定。
# doc/SPEC.md の決定事項(rootful Podman, ホストLinuxブリッジ+Podman bridge
# ネットワーク, /dev/kvm・/dev/fuseパススルー, --systemd=always)を
# NixOSの宣言的設定として再現する。
#
# イメージ自体(Dockerfileのビルド)はNixのサンドボックス外で
# `podman build -t <config.services.pvePodman.image> .` を実行して用意すること。
# ビルド時にDebian/Proxmoxのaptリポジトリへネットワークアクセスが必要なため、
# Nixの純粋ビルドでは再現していない。

{ config, lib, pkgs, ... }:

let
  cfg = config.services.pvePodman;
  containerName = "pve";
in
{
  options.services.pvePodman = {
    enable = lib.mkEnableOption "Podman上でのProxmox VE(PVE)コンテナのデプロイ";

    image = lib.mkOption {
      type = lib.types.str;
      default = "localhost/pve-podman:latest";
      description = "podman build で事前に用意しておくイメージ参照。";
    };

    networkName = lib.mkOption {
      type = lib.types.str;
      default = "pve-bridge";
      description = "作成するPodman bridgeネットワーク名。";
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "br-pve";
      description = ''
        parentIfaceをポートとして作成するホスト側Linuxブリッジ名。
        ホスト自身のIP(DHCP/static)は、parentIfaceではなくこの
        ブリッジインターフェースに設定する必要がある(doc/NIXOS.md参照)。
      '';
    };

    parentIface = lib.mkOption {
      type = lib.types.str;
      example = "eth0";
      description = "bridgeNameのポートにする物理NIC名。";
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.0/24";
      description = "PVEコンテナ/VMが属するLANのサブネット。";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.1";
      description = "そのLANのデフォルトゲートウェイ。";
    };

    pveIp = lib.mkOption {
      type = lib.types.str;
      example = "192.168.1.50";
      description = "PVEコンテナに割り当てる静的IP(PVE_IP)。";
    };

    pvePrefix = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "PVE_PREFIX(サブネットのプレフィックス長)。";
    };

    pveDns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PVE_DNS(スペース区切りのDNSサーバー一覧)。";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = "pve";
      description = ''
        コンテナのホスト名(PVEのノード名として表示される)。
        未指定のままだとPodmanが割り当てるコンテナID(ハッシュ値)が
        そのままノード名になってしまうため、明示的に設定する。
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "8006/tcp(PVE Web UI)をファイアウォールで開放するか。";
    };
  };

  config = lib.mkIf cfg.enable {
    # virtualisation.podman.enable はこのモジュール自身で下に設定するため
    # 通常このassertionが発火することはないが、他モジュール側で
    # 明示的に false 上書きされた場合に分かりやすいエラーで止めるためのガード。
    assertions = [
      {
        assertion = config.virtualisation.podman.enable;
        message = "services.pvePodman requires virtualisation.podman.enable = true;";
      }
    ];

    virtualisation.podman.enable = true;
    # oci-containers のデフォルトバックエンドはdocker。doc/SPEC.md 決定事項1の
    # 通りPodman(rootful)前提のため明示的に上書きする。
    virtualisation.oci-containers.backend = "podman";

    # pmxcfs(FUSE)に必要。/dev/kvm 用の kvm-intel/kvm-amd は
    # ハードウェア依存のため hardware-configuration.nix 側で有効化されている前提。
    boot.kernelModules = [ "fuse" ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 8006 ];

    # host/setup-bridge.sh 相当のブリッジ作成部分。parentIfaceをポートとする
    # Linuxブリッジを宣言的に作る。ホスト自身のIP設定はparentIfaceではなく
    # このブリッジ側へ移す必要がある(doc/NIXOS.md参照。本モジュールの対象外)。
    networking.bridges.${cfg.bridgeName}.interfaces = [ cfg.parentIface ];

    # host/setup-bridge.sh のPodmanネットワーク作成部分を宣言的に実行する
    # oneshot ユニット。mode=unmanagedのため、ブリッジ自体(上記)は
    # Podmanではなくnetworking.bridgesが作成・管理する。
    systemd.services."podman-network-${cfg.networkName}" = {
      description = "Create podman bridge network for PVE (${cfg.networkName})";
      after = [ "network-online.target" "sys-subsystem-net-devices-${cfg.bridgeName}.device" ];
      wants = [ "network-online.target" ];
      requires = [ "sys-subsystem-net-devices-${cfg.bridgeName}.device" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # 既に存在する場合は再作成しない(nixos-rebuild switch を
        # 何度実行しても安全な冪等スクリプトにするため)。
        ${config.virtualisation.podman.package}/bin/podman network exists ${cfg.networkName} || \
          ${config.virtualisation.podman.package}/bin/podman network create -d bridge \
            -o mode=unmanaged \
            --interface-name ${cfg.bridgeName} \
            --subnet ${cfg.subnet} \
            --gateway ${cfg.gateway} \
            ${cfg.networkName}
      '';
    };

    virtualisation.oci-containers.containers.${containerName} = {
      image = cfg.image;
      autoStart = true;
      ports = [ "8006:8006" ];
      # 名前付きボリュームにしているのは doc/BACKUP.md の
      # `podman volume export/import` 手順とそのまま対応させるため。
      # ホストパスのbind mountにすると手順が変わってしまう。
      volumes = [
        "pve-var-lib-vz:/var/lib/vz"
        "pve-cluster:/var/lib/pve-cluster"
      ];
      environment = {
        NETWORK = "N"; # dockur/proxmox標準のNAT機構を無効化(SPEC.md 決定事項5)
        PVE_IP = cfg.pveIp;
        PVE_PREFIX = toString cfg.pvePrefix;
        PVE_GATEWAY = cfg.gateway;
        # PVE_DNS未指定時にentrypoint側の既定値処理を活かすため、
        # 空文字ではなく環境変数自体を生やさない(nullなら属性ごと省く)。
      } // lib.optionalAttrs (cfg.pveDns != null) { PVE_DNS = cfg.pveDns; };
      # oci-containers に systemd/privileged/device専用のオプションがないため
      # extraOptionsで直接podman runへ渡す。いずれもSPEC.md決定事項
      # (2・7)でrootful固定・KVM/FUSEパススルー必須と確定済みのもの。
      extraOptions = [
        "--systemd=always"
        "--privileged"
        "--hostname=${cfg.nodeName}"
        "--network=${cfg.networkName}"
        "--ip=${cfg.pveIp}"
        "--device=/dev/kvm"
        "--device=/dev/fuse"
      ];
    };

    # virtualisation.oci-containers.containers.pve から生成されるユニット名は
    # 慣習的に "podman-pve.service"。oci-containers はネットワーク作成ユニットへの
    # 依存を知らないため、ここで明示的にafter/requiresを追加する
    # (network create が終わる前にコンテナが起動してbridge接続に失敗するのを防ぐ)。
    systemd.services."podman-${containerName}" = {
      after = [ "podman-network-${cfg.networkName}.service" ];
      requires = [ "podman-network-${cfg.networkName}.service" ];
    };
  };
}
