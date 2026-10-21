{
  description = "Boot NixOS on a vendor-signed kernel to meet EAC Linux v2's boot requirements";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      eacnixPkgs = import ./pkgs { inherit pkgs; };
    in
    {
      nixosModules.default = ./modules/eacnix.nix;

      packages.${system} = {
        inherit (eacnixPkgs)
          fedora-kernel
          fedora-boot-chain
          eacnix-boot
          eacnix-check
          ;
      };
      # A package set, not a derivation, so it can't live in `packages`.
      legacyPackages.${system} = {
        inherit (eacnixPkgs) linuxPackages-fedora;
      };

      checks.${system} = {
        fedora-kernel-vm = pkgs.testers.runNixOSTest ./tests/fedora-kernel-vm.nix;
        secure-boot-vm = pkgs.testers.runNixOSTest ./tests/secure-boot-vm.nix;
        esp-full = pkgs.testers.runNixOSTest ./tests/esp-full.nix;
        # kernelPackages tools that build from `kernel.src` with `kernel.stdenv`.
        kernel-tools = pkgs.linkFarmFromDrvs "eacnix-kernel-tools" (
          with eacnixPkgs.linuxPackages-fedora;
          [
            turbostat
            cpupower
            x86_energy_perf_policy
            usbip
            tmon
          ]
        );
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
