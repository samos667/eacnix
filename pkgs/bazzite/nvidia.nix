# NVIDIA's driver for the Bazzite path: Universal Blue's signed builds of
# NVIDIA's kernel modules for one kernel flavour, byte-for-byte, and NVIDIA's
# userspace at the same version. The `ogc` kernel gets the open modules, the
# `ogc-lts` kernel the proprietary ones (see sources.nix).
#
# The modules are signed with Universal Blue's kernel certificate, the MOK
# the Bazzite path already needs enrolled; the kernel trusts them through it.
{
  lib,
  stdenvNoCC,
  fetchurl,
  rpm,
  cpio,
  kmod,
  xz,
  # linuxPackagesFor the Bazzite kernel, for nixpkgs' NVIDIA builder.
  linuxPackages,
  sources,
}:

let
  inherit (sources) kernel nvidia;

  modules = stdenvNoCC.mkDerivation {
    pname = "nvidia-${if nvidia.proprietary then "proprietary" else "open"}-bazzite";
    version = "${nvidia.version}-${kernel.version}";
    src = fetchurl nvidia.akmods;
    sourceRoot = ".";
    unpackCmd = "tar -xzf $curSrc rpms/kmods/${nvidia.kmod}";
    nativeBuildInputs = [
      rpm
      cpio
      kmod
      xz
    ];
    installPhase = ''
      rpm2cpio rpms/kmods/${nvidia.kmod} | cpio -idm --quiet
      d=lib/modules/${kernel.modDirVersion}
      # The userspace below must match the modules exactly.
      for m in $(find $d -name 'nvidia*.ko*'); do
        v=$(modinfo -F version $m)
        if [ "$v" != ${nvidia.version} ]; then
          echo "$m is NVIDIA $v; pkgs/bazzite/sources.nix pins ${nvidia.version}" >&2
          exit 1
        fi
      done
      mkdir -p $out/lib/modules
      cp -a $d $out/lib/modules/
      # nixpkgs' module aggregator expects a certificate next to each external
      # module (see ../vendor-kernel.nix); the MOK holds the real one.
      find $out -name '*.ko*' | sed -E 's/\.(xz|zst|gz)$//; s/$/.cer/' | xargs touch
    '';
    dontFixup = true;
    # modules/eacnix.nix lets these through its boot.extraModulePackages check.
    passthru.eacnix.vendorSigned = true;
    meta = {
      description = "Universal Blue-signed NVIDIA ${
        if nvidia.proprietary then "proprietary" else "open"
      } GPU kernel modules ${nvidia.version} for ${kernel.modDirVersion}";
      license =
        if nvidia.proprietary then
          lib.licenses.unfreeRedistributable
        else
          with lib.licenses;
          [
            mit
            gpl2Only
          ];
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
# The GSP firmware comes from NVIDIA's .run (nixpkgs extracts it only when it
# builds the open modules itself, hence `firmware = true`). NixOS's
# hardware.nvidia installs `.open` or `.mod`; only one of them exists here,
# and nothing is built against the kernel tree, which a vendor kernel lacks.
((linuxPackages.nvidiaPackages.mkDriver nvidia.userspace).override { firmware = true; })
.overrideAttrs
  (old: {
    passthru =
      old.passthru
      // (
        if nvidia.proprietary then
          {
            mod = modules;
            open = null;
          }
        else
          {
            open = modules;
            mod = throw "eacnix: Bazzite's ${kernel.modDirVersion} kernel only has NVIDIA's open modules (hardware.nvidia.open = true).";
          }
      );
  })
