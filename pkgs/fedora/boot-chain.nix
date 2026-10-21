# Fedora's signed shim and grub, byte-for-byte. shim is signed by the Microsoft
# UEFI CA and embeds `fedoraca` (Fedora Secure Boot CA 20200709), which also
# signed grub and the kernel.
{
  lib,
  stdenvNoCC,
  fetchurl,
  rpm,
  cpio,
  sources,
}:

stdenvNoCC.mkDerivation {
  pname = "fedora-boot-chain";
  version = "shim-${sources.shim.version}-${sources.shim.release}+grub-${sources.grub.version}-${sources.grub.release}";

  srcs = [
    (fetchurl sources.shim.rpm)
    (fetchurl sources.grub.rpm)
  ];
  sourceRoot = ".";

  nativeBuildInputs = [
    rpm
    cpio
  ];

  unpackCmd = "rpm2cpio $curSrc | cpio -idm --quiet";

  installPhase = ''
    runHook preInstall
    shim=usr/lib/efi/shim/${sources.shim.version}-${sources.shim.release}/EFI/fedora
    grub="usr/lib/efi/grub2/1:${sources.grub.version}-${sources.grub.release}/EFI/fedora"
    install -Dm444 -t $out/EFI/fedora $shim/shimx64.efi $shim/mmx64.efi "$grub/grubx64.efi"
    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "Fedora's Microsoft-signed shim and Fedora-signed grub";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
