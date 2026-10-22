{ pkgs }:

let
  fedoraSources = import ./fedora/sources.nix;
  bazziteSources = import ./bazzite/sources.nix;

  # Everything eacnix takes from one vendor, for modules/eacnix.nix to pick
  # from with `eacnix.vendor`. `chainDir` must match VENDORS in eacnix-boot.py.
  vendor =
    {
      kernel,
      bootChain,
      chainDir,
      # Well-known MOK certificates the vendor's boot path needs enrolled.
      moks ? [ ],
      # NVIDIA's driver with the vendor's signed open modules (`.open`), or
      # null when the vendor ships none.
      nvidia ? null,
    }:
    {
      inherit
        kernel
        bootChain
        moks
        nvidia
        ;
      linuxPackages = pkgs.linuxPackagesFor kernel;
      eacnix-check = pkgs.callPackage ./eacnix-check {
        shim = "${bootChain}/${chainDir}/shimx64.efi";
        wellKnownMoks = moks;
      };
    };
in
rec {
  fedora-kernel = pkgs.callPackage ./fedora/kernel.nix {
    sources = fedoraSources;
    # Otherwise callPackage fills it from pkgs.kernelPatches.
    kernelPatches = [ ];
  };
  fedora-boot-chain = pkgs.callPackage ./fedora/boot-chain.nix { sources = fedoraSources; };

  # Bazzite's two kernel flavours (see bazzite/sources.nix), each with the
  # NVIDIA modules Universal Blue builds for it.
  bazzite-kernel = pkgs.callPackage ./bazzite/kernel.nix {
    sources = bazziteSources.ogc // {
      inherit (bazziteSources) release;
    };
    kernelPatches = [ ];
  };
  bazzite-nvidia = pkgs.callPackage ./bazzite/nvidia.nix {
    sources = bazziteSources.ogc;
    linuxPackages = vendors.bazzite.linuxPackages;
  };
  bazzite-lts-kernel = pkgs.callPackage ./bazzite/kernel.nix {
    sources = bazziteSources.ogc-lts // {
      inherit (bazziteSources) release;
    };
    kernelPatches = [ ];
  };
  bazzite-lts-nvidia = pkgs.callPackage ./bazzite/nvidia.nix {
    sources = bazziteSources.ogc-lts;
    linuxPackages = vendors.bazzite-lts.linuxPackages;
  };

  vendors = {
    fedora = vendor {
      kernel = fedora-kernel;
      bootChain = fedora-boot-chain;
      chainDir = "EFI/fedora";
    };
    # Bazzite boots through Fedora's shim and grub; shim accepts its kernel
    # through Universal Blue's MOK. modules/eacnix.nix picks the flavour
    # (`eacnix.bazzite.kernel`).
    bazzite = vendor {
      kernel = bazzite-kernel;
      bootChain = fedora-boot-chain;
      chainDir = "EFI/fedora";
      moks = [ bazzite-kernel.mokCert ];
      nvidia = bazzite-nvidia;
    };
    bazzite-lts = vendor {
      kernel = bazzite-lts-kernel;
      bootChain = fedora-boot-chain;
      chainDir = "EFI/fedora";
      moks = [ bazzite-lts-kernel.mokCert ];
      nvidia = bazzite-lts-nvidia;
    };
  };

  linuxPackages-fedora = vendors.fedora.linuxPackages;
  linuxPackages-bazzite = vendors.bazzite.linuxPackages;
  linuxPackages-bazzite-lts = vendors.bazzite-lts.linuxPackages;

  eacnix-boot = pkgs.callPackage ./eacnix-boot { };
  # The check as packaged for Fedora; the module uses its vendor's.
  inherit (vendors.fedora) eacnix-check;
}
