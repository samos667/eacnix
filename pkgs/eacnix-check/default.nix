{
  lib,
  writers,
  makeWrapper,
  runCommand,
  python3,
  openssl,
  fedora-boot-chain,
}:

let
  unwrapped = writers.writePython3Bin "eacnix-check" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./eacnix-check.py);

  # The certificate shim trusts for grub and the kernel (its `.vendor_cert`
  # section). It always shows up in MokListRT; anything else there is a MOK.
  vendorCert =
    runCommand "fedora-shim-vendor-cert"
      {
        nativeBuildInputs = [
          python3
          openssl
        ];
      }
      ''
        python3 - ${fedora-boot-chain}/EFI/fedora/shimx64.efi vendor-cert.der <<'EOF'
        import struct, sys
        pe = open(sys.argv[1], "rb").read()
        off = struct.unpack_from("<I", pe, 0x3C)[0]
        nsec, optsize = struct.unpack_from("<H", pe, off + 6)[0], struct.unpack_from("<H", pe, off + 20)[0]
        # Names longer than 8 bytes are stored as "/<offset>" into the COFF string table.
        symtab, nsyms = struct.unpack_from("<II", pe, off + 12)
        strtab = symtab + 18 * nsyms
        def name(raw):
            raw = raw.rstrip(b"\0")
            if raw.startswith(b"/"):
                start = strtab + int(raw[1:])
                return pe[start:pe.index(b"\0", start)]
            return raw
        for i in range(nsec):
            sec = off + 24 + optsize + 40 * i
            if name(pe[sec:sec + 8]) == b".vendor_cert":
                raw = struct.unpack_from("<I", pe, sec + 20)[0]
                size, _, cert_off, _ = struct.unpack_from("<IIII", pe, raw)
                open(sys.argv[2], "wb").write(pe[raw + cert_off:raw + cert_off + size])
                break
        else:
            sys.exit("shim has no .vendor_cert section")
        EOF
        openssl x509 -inform DER -in vendor-cert.der -noout -subject
        install -Dm444 vendor-cert.der $out
      '';
in
runCommand "eacnix-check"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit vendorCert; };
    meta.mainProgram = "eacnix-check";
  }
  ''
    makeWrapper ${lib.getExe unwrapped} $out/bin/eacnix-check \
      --add-flags "--vendor-cert ${vendorCert}"
  ''
