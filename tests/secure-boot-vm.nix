# The full eac path under real Secure Boot, with a software TPM:
# firmware -> Fedora shim -> Fedora grub -> Fedora kernel -> NixOS (eac).
#
# The disk image can't be built with Secure Boot on: make-disk-image boots its
# builder kernel through the same OVMF, which would refuse it. So:
#   1. The image is built without Secure Boot. eacnix-boot registers the
#      firmware entry, and the image's BootNext points at it.
#   2. First boot takes the eac path; the guest sets BootNext again (what
#      `eac-reboot` does) and shuts down.
#   3. The host enrolls a generated PK plus Microsoft's KEK and db into the
#      VM's variable store and turns Secure Boot on: nothing but Microsoft
#      certificates in db, like a stock machine.
#   4. Second boot has to pass Secure Boot through shim.
# The normal entry is unsigned systemd-boot, which step 3's firmware refuses.
{ lib, pkgs, ... }:

{
  name = "eacnix-secure-boot-vm";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../modules/eacnix.nix ];
      eacnix = {
        enable = true;
        boot.addToBootOrder = true;
      };

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        tpm.enable = true;
        memorySize = 2048;
      };

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot.extraInstallCommands = lib.mkAfter ''
        ${lib.getExe config.system.build.eacnix.eacnix-boot} next
      '';

      environment.systemPackages = [
        pkgs.tpm2-tools
        pkgs.efibootmgr
      ];
    };

  testScript = ''
    import glob
    import json
    import os
    import re
    import subprocess

    def boot_order():
        out = machine.succeed("efibootmgr")
        order = re.search(r"^BootOrder: (\S+)", out, re.M)
        eac = re.search(r"^Boot([0-9A-F]{4})\* NixOS EAC", out, re.M)
        assert order and eac, out
        return order.group(1).split(","), eac.group(1)

    def check_statuses():
        """eacnix-check's verdicts, by check id."""
        status, out = machine.execute("eacnix-check --json")
        results = {x["id"]: x["status"] for x in json.loads(out)}
        print(json.dumps(json.loads(out), indent=2))
        return status, results

    with subtest("first boot, without Secure Boot, takes the eac path"):
        machine.wait_for_unit("multi-user.target")
        machine.succeed("uname -r | grep -q fc45")
        # grub prepends BOOT_IMAGE=<path of the kernel it loaded>.
        machine.succeed("grep -q 'BOOT_IMAGE=.*/EFI/eacnix/kernels/' /proc/cmdline")
        machine.succeed("bootctl status 2>/dev/null | grep -q 'Secure Boot: disabled'")

    with subtest("systemd-boot lists the normal system but not the eac specialisation"):
        machine.succeed("grep -l \"init=$(readlink -f /nix/var/nix/profiles/system)/init\" /boot/loader/entries/*.conf")
        machine.fail("grep -l \"init=$(readlink -f /nix/var/nix/profiles/system/specialisation/eac)/init\" /boot/loader/entries/*.conf")

    with subtest("eacnix-check fails only Secure Boot (and the VM's missing IOMMU)"):
        status, results = check_statuses()
        assert status == 1, status
        failed = sorted(k for k, v in results.items() if v == "fail")
        assert failed == ["iommu", "secure-boot"], failed

    with subtest("addToBootOrder lists the eac entry once, never first"):
        # It was appended when the image was built; OVMF then appended its own
        # auto-generated entries behind it, so it isn't necessarily last.
        order, eac = boot_order()
        print(f"BootOrder {order}, eac entry {eac}")
        assert order.count(eac) == 1 and order[0] != eac, order

    with subtest("after a firmware reset drops it, the next install appends it again"):
        others = [n for n in order if n != eac]
        machine.succeed(f"efibootmgr --bootorder {','.join(others)}")
        machine.succeed("/nix/var/nix/profiles/system/bin/switch-to-configuration boot")
        new_order, _ = boot_order()
        assert new_order == others + [eac], new_order
        machine.succeed("/nix/var/nix/profiles/system/bin/switch-to-configuration boot")
        assert boot_order()[0] == new_order, "a second install changed BootOrder"
        machine.succeed("eacnix-boot next")
        machine.shutdown()

    with subtest("enroll Microsoft's keys and turn Secure Boot on"):
        (vars_file,) = glob.glob(os.path.join(machine.state_dir, "*-efi-vars.fd"))
        subprocess.run(
            [
                "${lib.getExe' pkgs.python3Packages.virt-firmware "virt-fw-vars"}",
                "--input", vars_file, "--output", vars_file + ".sb",
                "--enroll-generate", "eacnix test PK",
                "--microsoft-kek", "all", "--microsoft-db", "all",
                "--sb",
            ],
            check=True,
        )
        os.replace(vars_file + ".sb", vars_file)

    with subtest("second boot passes Secure Boot through Fedora's shim"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("uname -r | grep -q fc45")
        machine.succeed("grep -q 'BOOT_IMAGE=.*/EFI/eacnix/kernels/' /proc/cmdline")
        machine.succeed("bootctl status 2>/dev/null | grep -q 'Secure Boot: enabled (user)'")

    with subtest("EAC requirements"):
        machine.succeed("grep -q '\\[integrity\\]' /sys/kernel/security/lockdown")
        machine.succeed("grep -qw bpf /sys/kernel/security/lsm")
        machine.succeed("test $(cat /proc/sys/kernel/kexec_load_disabled) = 1")
        machine.succeed("test -e /dev/tpmrm0")

    with subtest("eacnix-check passes everything but the VM's missing IOMMU"):
        status, results = check_statuses()
        expected = {k: "pass" for k in results} | {"iommu": "fail"}
        assert results == expected, results

    with subtest("measured boot: the TPM log covers shim, grub and the kernel"):
        eventlog = machine.succeed("tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements")
        print(eventlog)
        assert "kernel_cmdline" in eventlog, "grub didn't measure the kernel command line"
  '';
}
