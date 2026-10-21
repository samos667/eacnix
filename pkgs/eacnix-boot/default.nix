{
  lib,
  writers,
  makeWrapper,
  runCommand,
  efibootmgr,
  util-linux,
}:

let
  unwrapped = writers.writePython3Bin "eacnix-boot" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./eacnix-boot.py);
in
runCommand "eacnix-boot"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "eacnix-boot";
  }
  ''
    makeWrapper ${lib.getExe unwrapped} $out/bin/eacnix-boot \
      --prefix PATH : ${
        lib.makeBinPath [
          efibootmgr
          util-linux
        ]
      }
  ''
