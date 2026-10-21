# NixOS userspace on Fedora's signed kernel, without Secure Boot.
# `lockdown=integrity` (set by the module) enforces module signatures on its
# own, so loading modules here proves their signatures survived packaging.
{ pkgs, ... }:

{
  name = "eacnix-fedora-kernel-vm";

  nodes.machine = {
    imports = [ ../modules/eacnix.nix ];
    eacnix = {
      enable = true;
      mode = "system";
      # Direct kernel boot, no bootloader: tests/secure-boot-vm.nix covers the ESP.
      boot.install = false;
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.xz
    ];
    # A sched_ext scheduler: its BPF program reads kernel config, which Fedora's
    # kernel only provides through eacnix.kconfigServices.
    services.scx = {
      enable = true;
      scheduler = "scx_lavd";
    };
  };

  testScript =
    { nodes, ... }:
    let
      kernel = nodes.machine.boot.kernelPackages.kernel;
      modules = "/run/booted-system/kernel-modules/lib/modules/${kernel.modDirVersion}";
    in
    ''
      machine.wait_for_unit("multi-user.target")

      with subtest("Fedora's kernel is running"):
          machine.succeed("test $(uname -r) = ${kernel.modDirVersion}")

      with subtest("EAC requirements that don't need Secure Boot"):
          machine.succeed("grep -q '\\[integrity\\]' /sys/kernel/security/lockdown")
          machine.succeed("grep -qw bpf /sys/kernel/security/lsm")
          machine.succeed("test $(cat /proc/sys/kernel/kexec_load_disabled) = 1")

      with subtest("signed modules load"):
          machine.succeed("modprobe 8021q")
          # Taint bit 13 (E): an unsigned module was loaded.
          machine.succeed("test $(( $(cat /proc/sys/kernel/tainted) & 8192 )) = 0")

      with subtest("an scx scheduler loads its BPF program and takes over"):
          machine.wait_until_succeeds("grep -qx enabled /sys/kernel/sched_ext/state", timeout=60)
          machine.succeed("systemctl is-active scx")
          machine.succeed("test -s /sys/kernel/sched_ext/root/ops")

      with subtest("a module with its signature stripped is refused"):
          machine.succeed(
              "xz -dc ${modules}/kernel/drivers/net/dummy.ko.xz > /tmp/dummy.ko",
              "python3 -c \"import struct; d=open('/tmp/dummy.ko','rb').read()[:-28];"
              " n=struct.unpack('>I', d[-4:])[0];"
              " open('/tmp/dummy-unsigned.ko','wb').write(d[:-12-n])\"",
          )
          machine.succeed("insmod /tmp/dummy.ko && rmmod dummy")
          machine.fail("insmod /tmp/dummy-unsigned.ko")
    '';
}
