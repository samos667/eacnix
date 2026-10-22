# Bazzite's kernel (the Open Gaming Collective kernel, signed by Universal
# Blue) of one flavour (`ogc` or `ogc-lts`, see sources.nix), unpacked from
# the RPMs in Universal Blue's akmods image. The rest is shared with every
# vendor; see ../vendor-kernel.nix.
#
# vmlinuz is signed only with Universal Blue's own certificates, so shim
# accepts it only once that certificate is enrolled as a MOK (`mokCert`).
# Its in-tree modules are signed with the kernel's per-build key.
{
  lib,
  stdenvNoCC,
  fetchurl,
  rpm,
  cpio,
  openssl,
  sbsigntool,
  callPackage,
  sources,
  kernelPatches ? [ ],
  randstructSeed ? "",
  features ? { },
}:

let
  inherit (sources.kernel) version modDirVersion;

  akmods = stdenvNoCC.mkDerivation {
    pname = "bazzite-akmods";
    inherit version;
    src = fetchurl sources.kernel.akmods;
    sourceRoot = ".";
    unpackCmd = "tar -xzf $curSrc";
    installPhase = "cp -a . $out";
    dontFixup = true;
  };

  rpms = lib.concatMapStringsSep " " (p: "${akmods}/kernel-rpms/${p}-${modDirVersion}.rpm") [
    "kernel-core"
    "kernel-modules"
  ];

  # Universal Blue's kernel signing certificate, from ublue-os-akmods-addons
  # in the same image: the MOK users enroll (`ujust enroll-secure-boot-key`
  # on Bazzite). The build checks that it signed this vmlinuz.
  mokCert = stdenvNoCC.mkDerivation {
    pname = "ublue-kernel-mok";
    inherit version;
    dontUnpack = true;
    nativeBuildInputs = [
      rpm
      cpio
      openssl
      sbsigntool
    ];
    installPhase = ''
      rpm2cpio ${akmods}/rpms/ublue-os/ublue-os-akmods-addons-*.rpm | cpio -idm --quiet
      der=etc/pki/akmods/certs/akmods-ublue.der
      openssl x509 -inform DER -in $der -noout -subject
      openssl x509 -inform DER -in $der -out cert.pem
      rpm2cpio ${akmods}/kernel-rpms/kernel-core-${modDirVersion}.rpm | cpio -idm --quiet ./lib/modules/${modDirVersion}/vmlinuz
      sbverify --cert cert.pem lib/modules/${modDirVersion}/vmlinuz
      install -Dm444 $der $out
    '';
    dontFixup = true;
  };
in
(callPackage ../vendor-kernel.nix {
  vendor = "bazzite";
  vendorName = "Bazzite";
  vendoredDir = "pkgs/bazzite/${sources.flavor}";
  inherit (sources) release;
  inherit (sources.kernel) version modDirVersion upstream;
  configfile = ./. + "/${sources.flavor}/kernel-config";
  moduleList = ./. + "/${sources.flavor}/kernel-modules.list";
  inherit kernelPatches randstructSeed features;

  unpacked = stdenvNoCC.mkDerivation {
    pname = "linux-bazzite-rpms";
    inherit version;
    dontUnpack = true;
    nativeBuildInputs = [
      rpm
      cpio
    ];
    installPhase = ''
      for r in ${rpms}; do rpm2cpio $r | cpio -idm --quiet; done
      m=lib/modules/${modDirVersion}
      mkdir $out
      mv $m/vmlinuz $out/vmlinuz
      cp $m/config $out/config
      # Install-time leftovers, as on Fedora.
      rm -rf $m/{.vmlinuz.hmac,build,source,updates,weak-updates,systemtap}
      mv $m $out/modules
    '';
    dontFixup = true;
  };
}).overrideAttrs
  (old: {
    passthru = old.passthru // {
      inherit akmods mokCert;
    };
  })
