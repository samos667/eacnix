# Fedora's signed kernel and modules, unpacked from Koji's RPMs. The rest is
# shared with every vendor; see ../vendor-kernel.nix.
{
  lib,
  stdenvNoCC,
  fetchurl,
  rpm,
  cpio,
  callPackage,
  sources,
  kernelPatches ? [ ],
  randstructSeed ? "",
  features ? { },
}:

let
  inherit (sources.kernel) version modDirVersion;
in
callPackage ../vendor-kernel.nix {
  vendor = "fedora";
  vendorName = "Fedora";
  inherit (sources) release;
  inherit (sources.kernel) version modDirVersion upstream;
  configfile = ./kernel-config;
  moduleList = ./kernel-modules.list;
  inherit kernelPatches randstructSeed features;

  unpacked = stdenvNoCC.mkDerivation {
    pname = "linux-fedora-rpms";
    inherit version;
    srcs = map fetchurl (lib.attrValues sources.kernel.rpms);
    sourceRoot = ".";
    nativeBuildInputs = [
      rpm
      cpio
    ];
    unpackCmd = "rpm2cpio $curSrc | cpio -idm --quiet";
    installPhase = ''
      m=lib/modules/${modDirVersion}
      mkdir $out
      mv $m/vmlinuz $out/vmlinuz
      cp $m/config $out/config
      # Install-time leftovers: the kernel lives at $out/bzImage, `build` and
      # `source` point into kernel-devel, the rest are empty hook directories.
      rm -rf $m/{.vmlinuz.hmac,build,source,updates,weak-updates,systemtap}
      mv $m $out/modules
    '';
    dontFixup = true;
  };
}
