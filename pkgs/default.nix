{ pkgs }:

let
  sources = import ./fedora/sources.nix;
in
rec {
  fedora-kernel = pkgs.callPackage ./fedora/kernel.nix {
    inherit sources;
    # Otherwise callPackage fills it from pkgs.kernelPatches.
    kernelPatches = [ ];
  };
  fedora-boot-chain = pkgs.callPackage ./fedora/boot-chain.nix { inherit sources; };
  linuxPackages-fedora = pkgs.linuxPackagesFor fedora-kernel;
  eacnix-boot = pkgs.callPackage ./eacnix-boot { };
  eacnix-check = pkgs.callPackage ./eacnix-check { inherit fedora-boot-chain; };
}
