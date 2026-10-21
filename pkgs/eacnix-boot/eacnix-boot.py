"""Install and select eacnix's vendor boot path on the ESP.

The layout under <esp>/EFI/<dir>/:
  shimx64.efi, mmx64.efi, grubx64.efi   vendor-signed, copied byte for byte
  grub.cfg                              points the signed grub at entries/
  entries/*.conf                        one BLS entry per eac generation
  kernels/                              kernels and initrds those entries use

Entries live outside /loader/entries so systemd-boot doesn't list them: booting
them through systemd-boot would put an unsigned loader in the measured chain.
For the same reason, `--hide-systemd-boot-entries` deletes the entries
systemd-boot itself writes for the eac specialisation.
"""

import argparse
import filecmp
import os
import re
import shutil
import subprocess
import sys

CHAIN = ("shimx64.efi", "mmx64.efi", "grubx64.efi")

# Headroom for FAT cluster rounding and directory entries.
SPACE_MARGIN = 1 << 20


class NoSpace(Exception):
    pass


def log(msg):
    print(f"eacnix-boot: {msg}", file=sys.stderr)


def up_to_date(src, dst):
    return os.path.exists(dst) and filecmp.cmp(src, dst, shallow=False)


def copy_if_changed(src, dst):
    """Copy atomically, so an interrupted install never leaves a torn binary."""
    if up_to_date(src, dst):
        return
    tmp = dst + ".tmp"
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
    except OSError:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def write_if_changed(path, text):
    if os.path.exists(path):
        with open(path) as f:
            if f.read() == text:
                return
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def generations(profile, subpath, limit=None):
    """Newest-first (number, toplevel) pairs that have an eac system."""
    profiles_dir = os.path.dirname(profile)
    name = os.path.basename(profile)
    pattern = re.compile(rf"^{re.escape(name)}-(\d+)-link$")
    found = []
    for entry in os.listdir(profiles_dir):
        m = pattern.match(entry)
        if not m:
            continue
        toplevel = os.path.join(profiles_dir, entry, subpath)
        if os.path.exists(os.path.join(toplevel, "kernel")):
            found.append((int(m.group(1)), os.path.realpath(toplevel)))
    found.sort(reverse=True)
    return found if limit is None else found[:limit]


def store_file_name(path):
    """`/nix/store/<hash>-<name>/<file>` -> `<hash>-<name>-<file>`, unique per content."""
    real = os.path.realpath(path)
    return f"{os.path.basename(os.path.dirname(real))}-{os.path.basename(real)}"


def install(args):
    efi_dir = f"EFI/{args.dir}"
    dest = os.path.join(args.esp, efi_dir)
    kernels = os.path.join(dest, "kernels")
    entries = os.path.join(dest, "entries")
    for d in (dest, kernels, entries):
        os.makedirs(d, exist_ok=True)

    gens = generations(args.profile, args.subpath, args.generations)
    if not gens:
        log(f"no generation of {args.profile} has {args.subpath or 'a kernel'}; nothing to install")

    # Plan everything first: what to copy, and the entry each generation gets.
    copies = [(os.path.join(args.chain, "EFI/fedora", f), os.path.join(dest, f)) for f in CHAIN]
    planned = []
    for number, toplevel in gens:
        files = {}
        for part in ("kernel", "initrd"):
            name = store_file_name(os.path.join(toplevel, part))
            copies.append((os.path.join(toplevel, part), os.path.join(kernels, name)))
            files[part] = f"/{efi_dir}/kernels/{name}"
        if os.path.exists(os.path.join(toplevel, "append-initrd-secrets")):
            log(f"generation {number}: initrd secrets aren't supported on the eac path")
        with open(os.path.join(toplevel, "kernel-params")) as f:
            params = f.read().strip()
        planned.append((
            f"nixos-eac-generation-{number}.conf",
            f"title NixOS EAC (generation {number})\n"
            f"version {number}\n"
            f"linux {files['kernel']}\n"
            f"initrd {files['initrd']}\n"
            f"options init={toplevel}/init {params}\n",
        ))

    # Prune before copying, so what this install drops counts as free space.
    # It's only what the install would delete anyway, plus leftovers from an
    # interrupted run. Entries go first, so none ever points at a missing file.
    wanted_kernels = {os.path.basename(dst) for _, dst in copies if os.path.dirname(dst) == kernels}
    wanted_entries = {entry for entry, _ in planned}
    for d, keep in ((entries, wanted_entries), (kernels, wanted_kernels)):
        for f in os.listdir(d):
            if f not in keep:
                os.remove(os.path.join(d, f))
    for f in os.listdir(dest):
        if f.endswith(".tmp"):
            os.remove(os.path.join(dest, f))

    # Check the space up front, so a full ESP fails before anything is written.
    # Duplicates (generations sharing a kernel) are counted once.
    pending = {dst: src for src, dst in copies if not up_to_date(src, dst)}
    needed = sum(os.path.getsize(src) for src in pending.values())
    free = shutil.disk_usage(dest).free
    if needed and needed + SPACE_MARGIN > free:
        raise NoSpace(
            f"not enough space on {args.esp}: the eac boot path needs {needed / 2**20:.1f} MiB "
            f"more (plus {SPACE_MARGIN / 2**20:.0f} MiB headroom), {free / 2**20:.1f} MiB is free. "
            "Nothing new was installed; the eac entries already on the ESP still work "
            "(generations past the limit were pruned). Lower eacnix.boot.generations "
            "or free space on the ESP."
        )

    for src, dst in copies:
        copy_if_changed(src, dst)
    # Each entry is written only once its kernel and initrd are in place.
    for entry, text in planned:
        write_if_changed(os.path.join(entries, entry), text)

    # Fedora's grub finds this file through `fw_path` (the directory it was
    # started from) before its built-in /EFI/fedora prefix. blscfg sorts by
    # `version`, newest first, and boots the first entry by default. Entries it
    # generates call `load_video`, which Fedora's own grub.cfg defines.
    write_if_changed(
        os.path.join(dest, "grub.cfg"),
        f"set timeout={args.timeout}\n"
        f"set blsdir=/{efi_dir}/entries\n"
        "function load_video {\n"
        "  insmod all_video\n"
        "}\n"
        "blscfg\n",
    )

    if args.hide_systemd_boot_entries:
        hide_systemd_boot_entries(args)
    if args.register:
        register(args, efi_dir)
    if args.add_to_boot_order:
        add_to_boot_order(args.label)
    log(f"installed {len(gens)} eac generation(s) to {dest}")


def hide_systemd_boot_entries(args):
    """Delete systemd-boot's entries that boot an eac system.

    systemd-boot lists every specialisation, and booting eac from its menu
    gives an unsigned loader in PCR 4. Its entries are named after a hash of
    their content, so they're matched by their `init=` path instead. It
    rewrites them on every install; this runs right after and removes them
    again. Every generation counts here, not only the ones installed above.
    """
    if not args.subpath:
        return  # In "system" mode every entry is an eac system; keep them.
    eac = {toplevel for _, toplevel in generations(args.profile, args.subpath)}
    entries = args.hide_systemd_boot_entries
    if not os.path.isdir(entries):
        return
    hidden = 0
    for f in os.listdir(entries):
        if not f.endswith(".conf"):
            continue
        path = os.path.join(entries, f)
        with open(path) as fh:
            m = re.search(r"^options\s+init=(\S+)/init\b", fh.read(), re.MULTILINE)
        if m and m.group(1) in eac:
            os.remove(path)
            hidden += 1
    if hidden:
        log(f"hid {hidden} eac entr{'y' if hidden == 1 else 'ies'} from systemd-boot's menu")


def efibootmgr(*argv):
    return subprocess.run(["efibootmgr", *argv], check=True, capture_output=True, text=True).stdout


def find_entry(label):
    for line in efibootmgr().splitlines():
        m = re.match(r"^Boot([0-9A-Fa-f]{4})\*? (.+?)(\t|  |$)", line)
        if m and m.group(2).strip() == label:
            return m.group(1)
    return None


def register(args, efi_dir):
    """Create the firmware entry once. BootOrder is left to the user."""
    if find_entry(args.label):
        return
    source = subprocess.run(
        ["findmnt", "--noheadings", "--output", "SOURCE", "--target", args.esp],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    part = os.path.basename(os.path.realpath(source))
    with open(f"/sys/class/block/{part}/partition") as f:
        number = f.read().strip()
    disk = os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{part}")))
    loader = "\\" + efi_dir.replace("/", "\\") + "\\shimx64.efi"
    efibootmgr("--create-only", "--disk", f"/dev/{disk}", "--part", number,
               "--label", args.label, "--loader", loader)
    log(f"registered firmware entry {args.label!r} -> {loader}")


def add_to_boot_order(label):
    """Append the entry to BootOrder if it's missing. Never reorder or remove.

    The firmware's boot menu only lists entries in BootOrder. Appending keeps
    the user's default first; a firmware that rebuilt BootOrder (BIOS update,
    CMOS reset) gets the entry back on the next install.
    """
    num = find_entry(label)
    if num is None:
        log(f"no firmware entry named {label!r}; can't add it to BootOrder")
        return
    m = re.search(r"^BootOrder: ?(\S*)", efibootmgr(), re.MULTILINE)
    order = [n for n in (m.group(1).split(",") if m else []) if n]
    if num.upper() in (n.upper() for n in order):
        return
    efibootmgr("--bootorder", ",".join([*order, num]))
    log(f"appended Boot{num} ({label}) to BootOrder")


def next_boot(args):
    num = find_entry(args.label)
    if num is None:
        sys.exit(f"eacnix-boot: no firmware entry named {args.label!r}; run `eacnix-boot install --register`")
    efibootmgr("--bootnext", num)
    log(f"next boot: Boot{num} ({args.label})")


def main():
    p = argparse.ArgumentParser(prog="eacnix-boot")
    sub = p.add_subparsers(dest="cmd", required=True)

    i = sub.add_parser("install", help="sync the vendor boot path on the ESP")
    i.add_argument("--esp", required=True)
    i.add_argument("--chain", required=True, help="store path of the vendor boot chain")
    i.add_argument("--dir", default="eacnix", help="directory under <esp>/EFI")
    i.add_argument("--profile", default="/nix/var/nix/profiles/system")
    i.add_argument("--subpath", default="specialisation/eac",
                   help="eac system inside each generation ('' for the generation itself)")
    i.add_argument("--generations", type=int, default=3)
    i.add_argument("--timeout", type=int, default=3)
    i.add_argument("--label", default="NixOS EAC")
    i.add_argument("--register", action="store_true", help="create the firmware entry if missing")
    i.add_argument("--add-to-boot-order", action="store_true",
                   help="append the firmware entry to BootOrder if it's missing")
    i.add_argument("--hide-systemd-boot-entries", metavar="DIR",
                   help="delete systemd-boot's entries in DIR that boot an eac system")
    i.set_defaults(func=install)

    n = sub.add_parser("next", help="boot the eac entry once, on the next boot")
    n.add_argument("--label", default="NixOS EAC")
    n.set_defaults(func=next_boot)

    args = p.parse_args()
    try:
        args.func(args)
    except NoSpace as e:
        log(str(e))
        sys.exit(2)
    except OSError as e:
        log(f"failed: {e}. Entries already on the ESP point only at files that are in place.")
        sys.exit(1)


if __name__ == "__main__":
    main()
