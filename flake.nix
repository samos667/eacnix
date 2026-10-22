{
  description = "Boot NixOS on a vendor-signed kernel to meet EAC Linux v2's boot requirements";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Only for checks.lanzaboote-vm; the module detects lanzaboote by itself.
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pre-commit.follows = "";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      lanzaboote,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # For the NVIDIA checks: NVIDIA's userspace is unfree.
      pkgsUnfree = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          nvidia.acceptLicense = true;
        };
      };
      eacnixPkgs = import ./pkgs { inherit pkgs; };
    in
    {
      nixosModules.default = ./modules/eacnix.nix;

      packages.${system} = {
        inherit (eacnixPkgs)
          fedora-kernel
          fedora-boot-chain
          bazzite-kernel
          bazzite-lts-kernel
          eacnix-boot
          eacnix-check
          ;
      };
      # A package set, not a derivation, so it can't live in `packages`.
      legacyPackages.${system} = {
        inherit (eacnixPkgs) linuxPackages-fedora linuxPackages-bazzite linuxPackages-bazzite-lts;
      };

      checks.${system} = {
        kernel-vm-fedora = pkgs.testers.runNixOSTest (import ./tests/kernel-vm.nix { vendor = "fedora"; });
        kernel-vm-bazzite = pkgs.testers.runNixOSTest (
          import ./tests/kernel-vm.nix { vendor = "bazzite"; }
        );
        kernel-vm-bazzite-lts = pkgs.testers.runNixOSTest (
          import ./tests/kernel-vm.nix {
            vendor = "bazzite";
            bazziteKernel = "ogc-lts";
            suffix = "bazzite-lts";
          }
        );
        secure-boot-vm-fedora = pkgs.testers.runNixOSTest (
          import ./tests/secure-boot-vm.nix { vendor = "fedora"; }
        );
        # With NVIDIA: its modules load only through Universal Blue's MOK.
        secure-boot-vm-bazzite = pkgsUnfree.testers.runNixOSTest (
          import ./tests/secure-boot-vm.nix {
            vendor = "bazzite";
            nvidia = "open";
          }
        );
        # The proprietary driver, which moves the eac path to Bazzite's LTS kernel.
        secure-boot-vm-bazzite-lts = pkgsUnfree.testers.runNixOSTest (
          import ./tests/secure-boot-vm.nix {
            vendor = "bazzite";
            nvidia = "proprietary";
            suffix = "bazzite-lts";
          }
        );
        esp-full = pkgs.testers.runNixOSTest ./tests/esp-full.nix;
        lanzaboote-vm = pkgs.testers.runNixOSTest (
          import ./tests/lanzaboote-vm.nix { inherit lanzaboote; }
        );
        # kernelPackages tools that build from `kernel.src` with `kernel.stdenv`.
        kernel-tools = pkgs.linkFarmFromDrvs "eacnix-kernel-tools" (
          pkgs.lib.concatMap
            (p: [
              p.turbostat
              p.cpupower
              p.x86_energy_perf_policy
              p.usbip
              p.tmon
            ])
            [
              eacnixPkgs.linuxPackages-fedora
              eacnixPkgs.linuxPackages-bazzite
              eacnixPkgs.linuxPackages-bazzite-lts
            ]
        );
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
