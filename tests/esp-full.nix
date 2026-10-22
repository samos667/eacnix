# eacnix-boot on an ESP that runs out of space. Fake generations with
# random-filled kernels and initrds fill a small FAT image on purpose.
#
# Fedora's shim + MokManager + grub (Bazzite uses the same) take ~6 MiB, so
# after generation 1 (4 MiB kernel + 4 MiB initrd) about 10 MiB is free:
#   - generation 2 (same kernel, 11 MiB initrd) doesn't fit next to
#     generation 1: the install must fail before writing anything;
#   - with --generations 1, generation 1's initrd is pruned first, and then it fits;
#   - generation 3 (a 20 MiB kernel) doesn't fit even after pruning: the
#     install fails after pruning, and the menu must not point at anything
#     that's gone.
{ pkgs, ... }:

let
  eacnixPkgs = import ../pkgs { inherit pkgs; };
in
{
  name = "eacnix-esp-full";

  nodes.machine = {
    environment.systemPackages = [
      eacnixPkgs.eacnix-boot
      pkgs.dosfstools
    ];
  };

  testScript = ''
    import re

    chain = "${eacnixPkgs.fedora-boot-chain}"
    dest = "/esp/EFI/eacnix"

    def generation(n, kernel, kernel_mib, initrd, initrd_mib):
        system = f"/tmp/store/gen{n}-system"
        machine.succeed(
            f"mkdir -p /tmp/store/{kernel} /tmp/store/{initrd} {system} /tmp/profiles",
            f"test -e /tmp/store/{kernel}/bzImage || head -c {kernel_mib}M /dev/urandom > /tmp/store/{kernel}/bzImage",
            f"test -e /tmp/store/{initrd}/initrd || head -c {initrd_mib}M /dev/urandom > /tmp/store/{initrd}/initrd",
            f"ln -sfn /tmp/store/{kernel}/bzImage {system}/kernel",
            f"ln -sfn /tmp/store/{initrd}/initrd {system}/initrd",
            f"echo quiet > {system}/kernel-params",
            f"ln -sfn {system} /tmp/profiles/system-{n}-link",
        )

    def install(generations):
        return (
            f"eacnix-boot install --esp /esp --chain {chain} --profile /tmp/profiles/system"
            f" --subpath ''' --generations {generations} 2>&1"
        )

    def esp_state():
        return machine.succeed("cd /esp && find . -type f | sort | xargs md5sum")

    def menu():
        """Generations the BLS entries list, and every file they point at."""
        entries = machine.succeed(f"cat {dest}/entries/*.conf 2>/dev/null || true")
        gens = re.findall(r"^version (\d+)$", entries, re.M)
        files = re.findall(r"^(?:linux|initrd) (\S+)$", entries, re.M)
        return sorted(int(g) for g in gens), files

    def assert_menu(expected):
        gens, files = menu()
        assert gens == expected, f"menu lists {gens}, expected {expected}"
        for f in files:
            machine.succeed(f"test -s /esp{f}")

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "truncate -s 24M /tmp/esp.img",
        "mkfs.vfat /tmp/esp.img",
        "mkdir /esp",
        "mount -o loop /tmp/esp.img /esp",
    )

    with subtest("generation 1 fits"):
        generation(1, "k1", 4, "i1", 4)
        machine.succeed(install(2))
        assert_menu([1])
        print(machine.succeed("df -m /esp"))

    with subtest("generation 2 doesn't fit next to generation 1: fail before writing"):
        generation(2, "k1", 4, "i2", 11)
        before = esp_state()
        status, out = machine.execute(install(2))
        print(out)
        assert status == 2, f"expected exit code 2, got {status}"
        assert "not enough space" in out, out
        assert esp_state() == before, "a failed install changed the ESP"
        machine.fail(f"find {dest} -name '*.tmp' | grep .")

    with subtest("leftovers from an interrupted run are removed"):
        machine.succeed(f"echo partial > {dest}/kernels/i2-initrd.tmp", f"echo partial > {dest}/grubx64.efi.tmp")

    with subtest("with --generations 1, generation 1 is pruned first and generation 2 fits"):
        machine.succeed(install(1))
        assert_menu([2])
        kernels = machine.succeed(f"ls {dest}/kernels").split()
        assert kernels == ["i2-initrd", "k1-bzImage"], kernels
        machine.fail(f"find {dest} -name '*.tmp' | grep .")
        machine.succeed(f"grep -q 'blsdir=/EFI/eacnix/entries' {dest}/grub.cfg")

    with subtest("generation 3 doesn't fit even after pruning: the menu points at nothing missing"):
        generation(3, "k3", 20, "i2", 11)
        status, out = machine.execute(install(1))
        print(out)
        assert status == 2, f"expected exit code 2, got {status}"
        # Generation 2's entry went with the pruning; generation 3 was never written.
        assert_menu([])
  '';
}
