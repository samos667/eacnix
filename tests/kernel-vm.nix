# NixOS userspace on a vendor's signed kernel, without Secure Boot.
# `lockdown=integrity` (set by the module) enforces module signatures on its
# own, so loading modules here proves their signatures survived packaging.
{
  vendor,
  # Bazzite's kernel flavour (`eacnix.bazzite.kernel`), and the test's suffix.
  bazziteKernel ? "ogc",
  suffix ? vendor,
}:
{ pkgs, ... }:

{
  name = "eacnix-kernel-vm-${suffix}";

  nodes.machine =
    { config, ... }:
    {
      imports = [ ../modules/eacnix.nix ];
      # A locally built (unsigned) module. With mode = "system" the eac config
      # is the whole system, so it's left out (and never built for the vendor
      # kernel) with a warning, instead of failing evaluation.
      boot.extraModulePackages = [ config.boot.kernelPackages.xpadneo ];
      eacnix = {
        enable = true;
        inherit vendor;
        bazzite.kernel = bazziteKernel;
        mode = "system";
        # Direct kernel boot, no bootloader: tests/secure-boot-vm.nix covers the ESP.
        boot.install = false;
      };
      environment.systemPackages = [
        pkgs.python3
        pkgs.xz
        pkgs.zstd
      ];
      # A sched_ext scheduler: its BPF program reads kernel config, which the
      # vendor's kernel only provides through eacnix.kconfigServices.
      services.scx = {
        enable = true;
        scheduler = "scx_lavd";
      };
    };

  testScript =
    { nodes, ... }:
    let
      kernel = nodes.machine.boot.kernelPackages.kernel;
    in
    ''
      machine.wait_for_unit("multi-user.target")

      with subtest("${kernel.eacnix.vendorName}'s kernel is running"):
          machine.succeed("test $(uname -r) = ${kernel.modDirVersion}")

      with subtest("EAC requirements that don't need Secure Boot"):
          machine.succeed("grep -q '\\[integrity\\]' /sys/kernel/security/lockdown")
          machine.succeed("grep -qw bpf /sys/kernel/security/lsm")
          machine.succeed("test $(cat /proc/sys/kernel/kexec_load_disabled) = 1")

      with subtest("the unsigned module is left out"):
          machine.fail("modinfo hid_xpadneo")

      with subtest("signed modules load"):
          machine.succeed("modprobe 8021q")
          # Taint bit 13 (E): an unsigned module was loaded.
          machine.succeed("test $(( $(cat /proc/sys/kernel/tainted) & 8192 )) = 0")

      with subtest("an scx scheduler loads its BPF program and takes over"):
          machine.wait_until_succeeds("grep -qx enabled /sys/kernel/sched_ext/state", timeout=60)
          machine.succeed("systemctl is-active scx")
          machine.succeed("test -s /sys/kernel/sched_ext/root/ops")

      with subtest("a module with its signature stripped is refused"):
          # Fedora compresses modules with xz; Bazzite doesn't.
          machine.succeed(
              "m=$(modinfo -n dummy); case $m in *.xz) xz -dc $m;; *.zst) zstd -dc $m;; *) cat $m;; esac > /tmp/dummy.ko",
              "python3 -c \"import struct; d=open('/tmp/dummy.ko','rb').read()[:-28];"
              " n=struct.unpack('>I', d[-4:])[0];"
              " open('/tmp/dummy-unsigned.ko','wb').write(d[:-12-n])\"",
          )
          machine.succeed("insmod /tmp/dummy.ko && rmmod dummy")
          machine.fail("insmod /tmp/dummy-unsigned.ko")
    '';
}
