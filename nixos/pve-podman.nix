# NixOSモジュール: Podman上でPVEコンテナをデプロイするホスト設定。
# doc/SPEC.md の決定事項(rootful Podman, macvlan, /dev/kvm・/dev/fuseパススルー,
# --systemd=always)をNixOSの宣言的設定として再現する。
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
      default = "pve-macvlan";
      description = "作成するPodman macvlanネットワーク名。";
    };

    parentIface = lib.mkOption {
      type = lib.types.str;
      example = "eth0";
      description = "macvlanの親にする物理NIC名。";
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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "8006/tcp(PVE Web UI)をファイアウォールで開放するか。";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.podman.enable;
        message = "services.pvePodman requires virtualisation.podman.enable = true;";
      }
    ];

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    # pmxcfs(FUSE)に必要。/dev/kvm 用の kvm-intel/kvm-amd は
    # ハードウェア依存のため hardware-configuration.nix 側で有効化されている前提。
    boot.kernelModules = [ "fuse" ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 8006 ];

    # host/setup-macvlan.sh 相当を宣言的に実行する oneshot ユニット。
    systemd.services."podman-network-${cfg.networkName}" = {
      description = "Create podman macvlan network for PVE (${cfg.networkName})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${config.virtualisation.podman.package}/bin/podman network exists ${cfg.networkName} || \
          ${config.virtualisation.podman.package}/bin/podman network create -d macvlan \
            -o parent=${cfg.parentIface} \
            --subnet ${cfg.subnet} \
            --gateway ${cfg.gateway} \
            ${cfg.networkName}
      '';
    };

    virtualisation.oci-containers.containers.${containerName} = {
      image = cfg.image;
      autoStart = true;
      ports = [ "8006:8006" ];
      volumes = [
        "pve-var-lib-vz:/var/lib/vz"
        "pve-cluster:/var/lib/pve-cluster"
      ];
      environment = {
        NETWORK = "N";
        PVE_IP = cfg.pveIp;
        PVE_PREFIX = toString cfg.pvePrefix;
        PVE_GATEWAY = cfg.gateway;
      } // lib.optionalAttrs (cfg.pveDns != null) { PVE_DNS = cfg.pveDns; };
      extraOptions = [
        "--systemd=always"
        "--privileged"
        "--network=${cfg.networkName}"
        "--ip=${cfg.pveIp}"
        "--device=/dev/kvm"
        "--device=/dev/fuse"
      ];
    };

    # oci-containers はネットワーク作成ユニットへの依存を知らないため明示する。
    systemd.services."podman-${containerName}" = {
      after = [ "podman-network-${cfg.networkName}.service" ];
      requires = [ "podman-network-${cfg.networkName}.service" ];
    };
  };
}
