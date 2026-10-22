# eacnix next to lanzaboote, with the owner's key and Microsoft's in db:
#   1. First boot, Secure Boot off: lanzaboote's normal NixOS, through the
#      firmware's fallback path (lanzaboote creates no Boot#### entry, so
#      BootOrder was empty when the image was built and eacnix didn't make
#      itself the default). eacnix has installed its path from lanzaboote's
#      install hook and removed lanzaboote's UKI for the eac specialisation.
#      A rebuild (switch-to-configuration boot) then registers its entry and
#      appends it behind the firmware's own.
#   2. The host enrolls lanzaboote's test PK/KEK, Microsoft's KEK and db, and
#      lanzaboote's test db certificate, then turns Secure Boot on.
#   3. Second boot: lanzaboote boots under Secure Boot with the owner's key.
#   4. Third boot, through BootNext: firmware -> Fedora shim -> grub -> kernel
#      on the same firmware.
{ lanzaboote }:
{ lib, pkgs, ... }:

let
  # lanzaboote's own test keys. pkiBundle refuses store paths, so the VM
  # exposes them under /etc.
  keys = "${lanzaboote}/nix/tests/fixtures/uefi-keys";
in
{
  name = "eacnix-lanzaboote-vm";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ../modules/eacnix.nix
        lanzaboote.nixosModules.lanzaboote
      ];
      eacnix = {
        enable = true;
        # OVMF drops Boot#### entries that neither BootOrder nor BootNext
        # references, so the entry has to be listed to survive the reboots
        # below (the MSI board in docs/findings.md keeps it either way).
        boot.addToBootOrder = true;
      };

      boot.lanzaboote = {
        enable = true;
        pkiBundle = "/etc/secureboot";
        # Its prepare-sb-auto-enroll service reruns lzbt directly at first
        # boot, recreating the eac UKI outside eacnix's install hook. The VM
        # is put in user mode by the test before systemd-boot could enroll.
        autoEnrollKeys.enable = true;
      };
      environment.etc.secureboot.source = keys;
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = true;

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        tpm.enable = true;
        memorySize = 2048;
      };

      environment.systemPackages = [ pkgs.efibootmgr ];
    };

  testScript = ''
    import glob
    import json
    import os
    import re
    import subprocess

    def check_statuses():
        """eacnix-check's verdicts, by check id."""
        status, out = machine.execute("eacnix-check --json")
        print(out)
        return status, {x["id"]: x["status"] for x in json.loads(out)}

    with subtest("first boot is lanzaboote's normal NixOS"):
        machine.wait_for_unit("multi-user.target")
        machine.fail("uname -r | grep -q fc45")
        machine.succeed("bootctl status 2>/dev/null | grep -q 'Secure Boot: disabled'")

    with subtest("eacnix installed its path from lanzaboote's install hook"):
        machine.succeed("test -e /boot/EFI/eacnix/shimx64.efi")
        machine.succeed("ls /boot/EFI/eacnix/entries/nixos-eac-generation-1.conf")

    with subtest("a rebuild registers the firmware entry behind the firmware's own"):
        machine.succeed("/nix/var/nix/profiles/system/bin/switch-to-configuration boot")
        out = machine.succeed("efibootmgr")
        print(out)
        order = re.search(r"^BootOrder: (\S+)", out, re.M)
        eac = re.search(r"^Boot([0-9A-F]{4})\* NixOS EAC", out, re.M)
        assert order and eac, out
        entries = order.group(1).split(",")
        assert entries.count(eac.group(1)) == 1 and entries[0] != eac.group(1), entries

    with subtest("lanzaboote's direct installer rerun is followed by eacnix's hiding"):
        machine.wait_for_unit("prepare-sb-auto-enroll.service")
        log_ = machine.succeed("journalctl -b -u prepare-sb-auto-enroll --no-pager")
        print(log_)
        assert "Installing Lanzaboote" in log_, "the service didn't rerun lzbt"
        assert "hid 1 eac UKI" in log_, "eacnix didn't hide the recreated UKI"

    with subtest("lanzaboote's UKI for the eac specialisation is hidden; the normal one stays"):
        ukis = machine.succeed("ls /boot/EFI/Linux").split()
        print(ukis)
        assert any(u.startswith("nixos-generation-1-") and "specialisation" not in u for u in ukis), ukis
        assert not any("specialisation-eac" in u for u in ukis), ukis
        machine.shutdown()

    with subtest("enroll the owner's key next to Microsoft's and turn Secure Boot on"):
        (vars_file,) = glob.glob(os.path.join(machine.state_dir, "*-efi-vars.fd"))
        guid = open("${keys}/GUID").read().strip()
        subprocess.run(
            [
                "${lib.getExe' pkgs.python3Packages.virt-firmware "virt-fw-vars"}",
                "--input", vars_file, "--output", vars_file + ".sb",
                "--enroll-cert", "${keys}/keys/PK/PK.pem",
                "--microsoft-kek", "all", "--microsoft-db", "all",
                "--add-db", guid, "${keys}/keys/db/db.pem",
                "--sb",
            ],
            check=True,
        )
        os.replace(vars_file + ".sb", vars_file)

    with subtest("lanzaboote boots under Secure Boot with the owner's key"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.fail("uname -r | grep -q fc45")
        machine.succeed("bootctl status 2>/dev/null | grep -q 'Secure Boot: enabled (user)'")
        machine.succeed("eacnix-boot next")
        machine.shutdown()

    with subtest("the eac path boots through Fedora's shim on the same firmware"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("uname -r | grep -q fc45")
        machine.succeed("grep -q 'BOOT_IMAGE=.*/EFI/eacnix/kernels/' /proc/cmdline")
        status, results = check_statuses()
        expected = {k: "pass" for k in results} | {"iommu": "fail"}
        assert results == expected, results
  '';
}
