# A vendor's signed kernel and modules, repackaged for boot.kernelPackages.
#
# Every vmlinuz and .ko byte must stay as the vendor shipped it: the kernel is
# Authenticode-signed and each module carries an appended PKCS#7 signature
# from a key built into this exact vmlinuz. Hence no fixup phase.
#
# `unpacked` holds the vendor's files in one layout for every vendor:
#   vmlinuz   the signed kernel
#   config    the kernel's build config
#   modules/  the tree for /lib/modules/<modDirVersion>, vendor install-time
#             leftovers removed
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  runCommand,
  kmod,
  # "fedora" or "bazzite".
  vendor,
  # Where configfile and moduleList live, for the stale-file message.
  vendoredDir ? "pkgs/${vendor}",
  # The vendor's name, for messages.
  vendorName,
  # The vendor release the kernel belongs to (e.g. "fc45", "26.04").
  release,
  version,
  modDirVersion,
  # Vanilla source of the same upstream version; see `src` below.
  upstream,
  unpacked,
  # Facts NixOS needs at evaluation time, vendored next to the vendor's
  # kernel.nix so evaluation needs no IFD. `vendored` regenerates them, and
  # the kernel build fails if the repo copies drift:
  #   nix build .#<vendor>-kernel.vendored && cp result/* <vendoredDir>/
  configfile,
  moduleList,
  # NixOS's boot.kernelPackages always calls kernel.override with these.
  # `features` is accepted and ignored: the vendor's feature set is fixed.
  kernelPatches ? [ ],
  randstructSeed ? "",
  features ? { },
}:

assert lib.assertMsg (
  kernelPatches == [ ]
) "eacnix: boot.kernelPatches can't be applied to ${vendorName}'s signed kernel.";
assert lib.assertMsg (
  randstructSeed == ""
) "eacnix: boot.kernel.randstructSeed can't be applied to ${vendorName}'s signed kernel.";

let
  vendored = runCommand "linux-${vendor}-${version}-vendored" { nativeBuildInputs = [ kmod ]; } ''
    mkdir $out
    cp ${unpacked}/config $out/kernel-config

    # Every name modprobe resolves: loadable and built-in modules plus their
    # plain-name aliases (e.g. ext2 -> ext4), folded the way modprobe matches.
    cp -r ${unpacked}/modules tree && chmod -R u+w tree
    mkdir -p root/lib/modules && mv tree root/lib/modules/${modDirVersion}
    depmod -b root ${modDirVersion}
    m=root/lib/modules/${modDirVersion}
    {
      find $m -name '*.ko*' -printf '%f\n' | sed -E 's/\.ko(\.xz|\.zst|\.gz)?$//'
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
  pname = "linux-${vendor}";
  inherit version;

  dontUnpack = true;
  nativeBuildInputs = [ kmod ];

  installPhase = ''
    runHook preInstall

    stale() {
      echo "${vendoredDir}/$1 is stale; see the comment in pkgs/vendor-kernel.nix." >&2
      exit 1
    }
    cmp -s ${vendored}/kernel-config ${configfile} || stale kernel-config
    cmp -s ${vendored}/kernel-modules.list ${moduleList} || stale kernel-modules.list

    install -Dm444 ${unpacked}/vmlinuz $out/bzImage
    mkdir -p $out/lib/modules
    dst=$out/lib/modules/${modDirVersion}
    cp -a ${unpacked}/modules $dst
    chmod -R u+w $out/lib/modules
    # The vendor runs depmod at install time; it only writes index files.
    depmod -b $out ${modDirVersion}

    # nixpkgs' module aggregator (boot.extraModulePackages) merges
    # certificates for nixpkgs' own module signing: `modules.cer` from the
    # kernel, plus a `<module>.ko.cer` for every module outside
    # modules.order (on Bazzite, amdgpu's KUnit tests). Only linuxPackages.rebuildImage
    # reads the result. A vendor's keys are already built into its vmlinuz,
    # so these are empty.
    cd $dst
    touch modules.cer
    comm -13 <(LC_ALL=C sort modules.order) \
      <(find . -name '*.ko*' -printf '%P\n' | sed -E 's/\.(xz|zst|gz)$//' | LC_ALL=C sort) \
      | sed 's/$/.cer/' | xargs -r touch
    cd - >/dev/null

    runHook postInstall
  '';

  dontFixup = true;

  passthru = {
    inherit
      version
      modDirVersion
      config
      configfile
      unpacked
      vendored
      ;
    # Every name modprobe resolves on this kernel (modules and aliases), `-` folded to `_`.
    moduleNames = lib.filter (n: n != "") (lib.splitString "\n" (builtins.readFile moduleList));
    # For kernelPackages tools built from the kernel tree; see the vendor's
    # sources.nix. linuxPackagesFor builds them with `kernel.stdenv`, which has
    # to have a compiler even though this unpack-only derivation doesn't.
    src = fetchurl upstream;
    patches = [ ];
    inherit stdenv;
    target = "bzImage";
    isModular = true;
    # Device trees are an ARM concern; no vendor ships any for x86_64.
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
      inherit vendor vendorName release;
    };
  };

  meta = {
    description = "${vendorName}'s signed Linux kernel and modules (${modDirVersion})";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
