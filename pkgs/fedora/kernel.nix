# Fedora's signed kernel and modules, repackaged for boot.kernelPackages.
#
# Every vmlinuz and .ko byte must stay as Fedora shipped it: the kernel is
# Authenticode-signed and each module carries an appended PKCS#7 signature
# from a per-build key baked into this exact vmlinuz. Hence no fixup phase.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  runCommand,
  rpm,
  cpio,
  kmod,
  sources,
  # NixOS's boot.kernelPackages always calls kernel.override with these.
  # `features` is accepted and ignored: Fedora's feature set is fixed.
  kernelPatches ? [ ],
  randstructSeed ? "",
  features ? { },
}:

assert lib.assertMsg (
  kernelPatches == [ ]
) "eacnix: boot.kernelPatches can't be applied to Fedora's signed kernel.";
assert lib.assertMsg (
  randstructSeed == ""
) "eacnix: boot.kernel.randstructSeed can't be applied to Fedora's signed kernel.";

let
  inherit (sources.kernel) version modDirVersion;

  # Facts NixOS needs at evaluation time are vendored next to this file, so
  # evaluation needs no IFD. `vendored` regenerates them from the RPMs, and the
  # kernel build fails if the repo copies drift:
  #   nix build .#fedora-kernel.vendored && cp result/* pkgs/fedora/
  configfile = ./kernel-config;
  moduleList = ./kernel-modules.list;

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
    installPhase = "cp -a lib/modules/${modDirVersion} $out";
    dontFixup = true;
  };

  vendored = runCommand "linux-fedora-${version}-vendored" { nativeBuildInputs = [ kmod ]; } ''
    mkdir $out
    cp ${unpacked}/config $out/kernel-config

    # Every name modprobe resolves: loadable and built-in modules plus their
    # plain-name aliases (e.g. ext2 -> ext4), folded the way modprobe matches.
    cp -r ${unpacked} tree && chmod -R u+w tree
    mkdir -p root/lib/modules && mv tree root/lib/modules/${modDirVersion}
    depmod -b root ${modDirVersion}
    m=root/lib/modules/${modDirVersion}
    {
      find $m/kernel -name '*.ko*' -printf '%f\n' | sed -E 's/\.ko(\.xz|\.zst|\.gz)?$//'
      sed -E 's|.*/||; s/\.ko$//' $m/modules.builtin
      awk '$1 == "alias" { print $2 }' $m/modules.alias
      tr '\0' '\n' < $m/modules.builtin.modinfo | sed -nE 's/^[^.]+\.alias=//p'
    } | grep -E '^[A-Za-z0-9_-]+$' | tr - _ | LC_ALL=C sort -u > $out/kernel-modules.list
  '';

  # Same shape as nixpkgs' kernel.config (pkgs/os-specific/linux/kernel/build.nix).
  config =
    let
      matchLine =
        line:
        let
          m = builtins.match "(CONFIG_[^=]+)=([ym])" line;
        in
        lib.optional (m != null) {
          name = builtins.elemAt m 0;
          value = builtins.elemAt m 1;
        };
      values = lib.listToAttrs (
        lib.concatMap matchLine (lib.splitString "\n" (builtins.readFile configfile))
      );
      attrName = attr: "CONFIG_" + attr;
    in
    rec {
      isSet = attr: values ? ${attrName attr};
      getValue = attr: values.${attrName attr} or null;
      isYes = attr: getValue attr == "y";
      isNo = attr: getValue attr == "n";
      isModule = attr: getValue attr == "m";
      isEnabled = attr: isModule attr || isYes attr;
      isDisabled = attr: !(isSet attr) || isNo attr;
    }
    // values;
in
stdenvNoCC.mkDerivation {
  pname = "linux-fedora";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ kmod ];

  installPhase = ''
    runHook preInstall

    stale() {
      echo "pkgs/fedora/$1 is stale; see the comment in pkgs/fedora/kernel.nix." >&2
      exit 1
    }
    cmp -s ${vendored}/kernel-config ${configfile} || stale kernel-config
    cmp -s ${vendored}/kernel-modules.list ${moduleList} || stale kernel-modules.list

    install -Dm444 ${unpacked}/vmlinuz $out/bzImage
    mkdir -p $out/lib/modules
    cp -a ${unpacked} $out/lib/modules/${modDirVersion}
    chmod -R u+w $out/lib/modules

    dst=$out/lib/modules/${modDirVersion}
    # Install-time leftovers: the kernel lives at $out/bzImage, `build` and
    # `source` point into kernel-devel, the rest are empty hook directories.
    rm -rf $dst/{vmlinuz,.vmlinuz.hmac,build,source,updates,weak-updates,systemtap}
    # Fedora runs depmod at install time; it only writes index files.
    depmod -b $out ${modDirVersion}

    runHook postInstall
  '';

  dontFixup = true;

  passthru = {
    inherit
      version
      modDirVersion
      config
      configfile
      vendored
      ;
    # Every name modprobe resolves on this kernel (modules and aliases), `-` folded to `_`.
    moduleNames = lib.filter (n: n != "") (lib.splitString "\n" (builtins.readFile moduleList));
    # For kernelPackages tools built from the kernel tree; see sources.nix.
    # linuxPackagesFor builds them with `kernel.stdenv`, which has to have a
    # compiler even though this unpack-only derivation doesn't.
    src = fetchurl sources.kernel.upstream;
    patches = [ ];
    inherit stdenv;
    target = "bzImage";
    isModular = true;
    # Device trees are an ARM concern; Fedora ships none for x86_64.
    buildDTBs = false;
    kernelOlder = lib.versionOlder version;
    kernelAtLeast = lib.versionAtLeast version;
    # Defining `features` makes NixOS skip system.requiredKernelConfig, so
    # modules/eacnix.nix re-checks it against `config`.
    features = {
      ia32Emulation = config.isYes "IA32_EMULATION";
      efiBootStub = config.isYes "EFI_STUB";
    };
    eacnix = {
      vendor = "fedora";
      inherit (sources) release;
    };
  };

  meta = {
    description = "Fedora's signed Linux kernel and modules (${modDirVersion})";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
