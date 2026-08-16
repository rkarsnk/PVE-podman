{
  description = "Podman上でProxmox VE(PVE)コンテナをデプロイするためのNixOSモジュール";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules.pvePodman = import ./nixos/pve-podman.nix;
    nixosModules.default = self.nixosModules.pvePodman;

    apps = builtins.listToAttrs (map
      (system: {
        name = system;
        value = {
          build-image = {
            type = "app";
            program = toString (nixpkgs.legacyPackages.${system}.writeShellScript "build-image" ''
              set -euo pipefail
              exec podman build -t pve-podman:latest "${self}"
            '');
          };
        };
      })
      [ "x86_64-linux" "aarch64-linux" ]);
  };
}
