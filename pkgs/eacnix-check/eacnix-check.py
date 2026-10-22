"""Check the running system against EAC Linux v2's published requirements.

EAC v2 isn't released, so this checks what Epic published, one requirement at
a time, from what the kernel, the EFI variables and the TPM event log say. A
pass here means "meets the published list", not "EAC accepts it".

Run it as root: the TPM event log and shim's MOK lists are root-only, and
those checks report `unknown` otherwise.
"""

import argparse
import json
import os
import re
import struct
import sys
import uuid

EFI_GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
SHIM_GUID = "605dab50-e046-4300-abb6-3dd810dd8b23"
LOADER_GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
EFIVARS = "/sys/firmware/efi/efivars"
MOK_VARIABLES = "/sys/firmware/efi/mok-variables"
EVENT_LOG = "/sys/kernel/security/tpm0/binary_bios_measurements"
X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")

EV_SEPARATOR = 0x4
EV_IPL = 0xD
EV_EFI_VARIABLE_DRIVER_CONFIG = 0x80000001
EV_EFI_BOOT_SERVICES_APPLICATION = 0x80000003
EV_EFI_ACTION = 0x80000007
EV_EFI_VARIABLE_AUTHORITY = 0x800000E0

PASS, WARN, FAIL, UNKNOWN = "pass", "warn", "fail", "unknown"


# --- readers -----------------------------------------------------------------


def read(path, mode="r"):
    """File contents, or None if it doesn't exist. PermissionError propagates."""
    try:
        with open(path, mode) as f:
            return f.read()
    except FileNotFoundError:
        return None


def efivar(name, guid=EFI_GLOBAL):
    """Raw value of an EFI variable (without the 4-byte attributes), or None."""
    data = read(f"{EFIVARS}/{name}-{guid}", "rb")
    return None if data is None else data[4:]


def utf16z(data):
    return data.decode("utf-16le", errors="replace").split("\0", 1)[0]


def file_paths(device_path):
    """Media file path nodes (type 4, subtype 4) of an EFI device path."""
    paths, off = [], 0
    while off + 4 <= len(device_path):
        typ, sub, length = struct.unpack_from("<BBH", device_path, off)
        if length < 4:
            break
        if typ == 0x04 and sub == 0x04:
            paths.append(utf16z(device_path[off + 4:off + length]))
        if typ == 0x7F and sub == 0xFF:
            break
        off += length
    return "".join(paths)


def boot_option(number):
    """(description, file path) of Boot####."""
    data = efivar(f"Boot{number:04X}")
    if data is None:
        return None, None
    _, path_len = struct.unpack_from("<IH", data, 0)
    desc_end = 6
    while data[desc_end:desc_end + 2] != b"\0\0":
        desc_end += 2
    description = data[6:desc_end].decode("utf-16le")
    dp = data[desc_end + 2:desc_end + 2 + path_len]
    return description, file_paths(dp)


def signature_lists(data):
    """(certificates, hash count) in a series of EFI_SIGNATURE_LISTs."""
    certs, hashes, off = [], 0, 0
    while off + 28 <= len(data):
        stype = uuid.UUID(bytes_le=data[off:off + 16])
        list_size, header_size, sig_size = struct.unpack_from("<III", data, off + 16)
        if list_size < 28 or sig_size <= 16:
            break
        for p in range(off + 28 + header_size, off + list_size, sig_size):
            entry = data[p + 16:p + sig_size]  # skip the owner GUID
            if stype == X509_GUID:
                certs.append(entry)
            else:
                hashes += 1
        off += list_size
    return certs, hashes


def common_name(der):
    """Last commonName in a DER certificate: the subject's, in practice."""
    names = []
    for m in re.finditer(rb"\x06\x03\x55\x04\x03([\x0c\x13\x14\x16])(.)", der, re.DOTALL):
        length = m.group(2)[0]
        names.append(der[m.end():m.end() + length].decode("utf-8", errors="replace"))
    return names[-1] if names else "?"


# Signing authorities on Epic's published list of well-known keys, matched by
# name in a certificate's subject or issuer, as Bazzite's `ujust
# check-anticheat` does. Epic's list (via The FPS Review): Canonical, Fedora,
# Universal Blue, Debian, openSUSE and SUSE, Rocky Linux, Microsoft's UEFI CA.
# A name can be copied into a self-made certificate, so name-only matches are
# reported as such.
WELL_KNOWN = re.compile(
    r"Canonical Ltd\. Master Certificate Authority|Fedora Secure Boot CA|Universal Blue"
    r"|Debian Secure Boot CA|openSUSE Secure Boot CA|SUSE Linux Enterprise Secure Boot CA"
    r"|Rocky Linux Secure Boot Root CA|Microsoft (Corporation )?UEFI CA"
)

# Name attributes: commonName, organizationName, organizationalUnitName.
NAME_ATTRS = {b"\x03": "CN", b"\x0a": "O", b"\x0b": "OU"}


def names(der):
    """Every CN, O and OU string in DER data (subjects and issuers alike)."""
    found = []
    for m in re.finditer(rb"\x06\x03\x55\x04([\x03\x0a\x0b])([\x0c\x13\x14\x16])(.)", der, re.DOTALL):
        length = m.group(3)[0]
        found.append(der[m.end():m.end() + length].decode("utf-8", errors="replace"))
    return found


def well_known(der):
    """The first well-known authority named in DER data, or None."""
    for name in names(der):
        if WELL_KNOWN.search(name):
            return name
    return None


def authenticode(path):
    """The PKCS#7 blobs in a PE image's certificate table (its Authenticode signatures)."""
    pe = read(path, "rb")
    if pe is None or pe[:2] != b"MZ":
        return None
    off = struct.unpack_from("<I", pe, 0x3C)[0]
    opt = off + 24
    magic = struct.unpack_from("<H", pe, opt)[0]
    dirs = opt + (112 if magic == 0x20B else 96)
    start, size = struct.unpack_from("<II", pe, dirs + 4 * 8)
    blobs, pos = [], start
    while pos + 8 <= start + size:
        length = struct.unpack_from("<I", pe, pos)[0]
        if length < 8:
            break
        blobs.append(pe[pos + 8:pos + length])
        pos += (length + 7) & ~7
    return blobs


# --- TPM event log -------------------------------------------------------------


def parse_event_log(data):
    """[(pcr, type, event data)] from a TCG2 crypto-agile event log."""
    # The first event uses the SHA-1-only format and carries the digest sizes.
    off = 8 + 20
    (size,) = struct.unpack_from("<I", data, off)
    spec = data[off + 4:off + 4 + size]
    off += 4 + size
    if not spec.startswith(b"Spec ID Event03"):
        raise ValueError("not a crypto-agile (TCG2) event log")
    (count,) = struct.unpack_from("<I", spec, 24)
    digest_sizes = dict(struct.unpack_from("<HH", spec, 28 + 4 * i) for i in range(count))

    events = []
    while off + 12 <= len(data):
        pcr, etype, ndigests = struct.unpack_from("<III", data, off)
        off += 12
        for _ in range(ndigests):
            (alg,) = struct.unpack_from("<H", data, off)
            off += 2 + digest_sizes[alg]
        (size,) = struct.unpack_from("<I", data, off)
        events.append((pcr, etype, data[off + 4:off + 4 + size]))
        off += 4 + size
    return events


def variable_event(data):
    """(name, value) of a UEFI_VARIABLE_DATA event."""
    name_len, data_len = struct.unpack_from("<QQ", data, 16)
    name = data[32:32 + 2 * name_len].decode("utf-16le")
    return name, data[32 + 2 * name_len:32 + 2 * name_len + data_len]


def image_event(data):
    """File path of a UEFI_IMAGE_LOAD_EVENT ('' when it has none)."""
    (dp_len,) = struct.unpack_from("<Q", data, 24)
    return file_paths(data[32:32 + dp_len])


# --- checks ------------------------------------------------------------------

class Report:
    def __init__(self):
        self.results = []

    def add(self, check_id, requirement, status, detail):
        self.results.append({"id": check_id, "requirement": requirement, "status": status, "detail": detail})


def check_boot_path(r, args):
    req = "Separate compliant boot entry"
    current = efivar("BootCurrent")
    if current is None:
        return r.add("boot-path", req, UNKNOWN, "no BootCurrent variable (not booted through UEFI?)")
    number = struct.unpack("<H", current[:2])[0]
    description, path = boot_option(number)
    loader = utf16z(efivar("LoaderInfo", LOADER_GUID) or b"")
    cmdline = read("/proc/cmdline") or ""
    shim = f"\\EFI\\{args.dir}\\shimx64.efi".lower()
    problems = []
    if not path or path.lower() != shim:
        problems.append(f"firmware started Boot{number:04X} ({description!r}, {path or '?'}), not {shim}")
    if loader and not loader.startswith("GRUB"):
        problems.append(f"loader is {loader!r}, not the vendor grub")
    if f"/EFI/{args.dir}/kernels/" not in cmdline:
        problems.append("kernel wasn't loaded from the eac entries (no matching BOOT_IMAGE=)")
    detail = f"Boot{number:04X} {description!r} -> {path}; loader {loader or '?'}"
    r.add("boot-path", req, FAIL if problems else PASS, "; ".join(problems) or detail)


def check_secure_boot(r):
    req = "UEFI Secure Boot"
    sb, setup = efivar("SecureBoot"), efivar("SetupMode")
    if sb is None:
        return r.add("secure-boot", req, UNKNOWN, "no SecureBoot variable")
    if sb[:1] != b"\x01" or setup[:1] != b"\x00":
        return r.add("secure-boot", req, FAIL, f"SecureBoot={sb[0]}, SetupMode={setup[0] if setup else '?'}")
    # `mokutil --disable-validation` makes shim boot anything while the
    # firmware still reports Secure Boot; shim then sets MokSBStateRT to 1.
    try:
        state = read(f"{MOK_VARIABLES}/MokSBStateRT", "rb")
    except PermissionError:
        state = None
    if state is None:
        state = efivar("MokSBStateRT", SHIM_GUID)
    if state and state[:1] == b"\x01":
        return r.add("secure-boot", req, FAIL,
                     "shim's validation is disabled (MokSBStateRT); re-enable it with 'mokutil --enable-validation'")
    r.add("secure-boot", req, PASS, "enabled, user mode, shim validating")


def check_tpm(r):
    req = "TPM 2.0"
    major = read("/sys/class/tpm/tpm0/tpm_version_major")
    if major is None:
        return r.add("tpm", req, FAIL, "no TPM at /sys/class/tpm/tpm0")
    r.add("tpm", req, PASS if major.strip() == "2" else FAIL, f"TPM version {major.strip()}")


def check_event_log(r, args):
    try:
        data = read(EVENT_LOG, "rb")
    except PermissionError:
        return r.add("event-log", "Measured boot", UNKNOWN, f"{EVENT_LOG} is root-only; run as root")
    if data is None:
        return r.add("event-log", "Measured boot", FAIL, "no TPM event log")
    req = "Measured boot: boot chain"
    events = parse_event_log(data)

    # PCR 4: the EFI applications the firmware and shim started, in order.
    # Under Secure Boot grub hands the kernel to shim, which loads it as one
    # more application (no device path); without it, grub loads the kernel
    # itself and only PCR 9 records it.
    apps = [image_event(d) for pcr, t, d in events if pcr == 4 and t == EV_EFI_BOOT_SERVICES_APPLICATION]
    chain = [f"\\EFI\\{args.dir}\\shimx64.efi".lower(), f"\\EFI\\{args.dir}\\grubx64.efi".lower()]
    ipl = [d.rstrip(b"\0").decode(errors="replace") for pcr, t, d in events if t == EV_IPL and pcr in (8, 9)]
    kernel_read = any(f"/EFI/{args.dir}/kernels/" in s and "bzImage" in s and not s.startswith(("grub_cmd", "kernel_cmdline")) for s in ipl)
    cmdline_measured = any(s.startswith("kernel_cmdline:") for s in ipl)
    shown = " -> ".join(a or "<kernel>" for a in apps)
    problems = []
    if [a.lower() for a in apps[:2]] != chain or any(a for a in apps[2:]) or len(apps) > 3:
        problems.append(f"PCR 4 holds {shown}; expected shim -> grub (-> kernel) only")
    if not kernel_read:
        problems.append("grub didn't measure the kernel image (PCR 9)")
    if not cmdline_measured:
        problems.append("grub didn't measure the kernel command line (PCR 8)")
    r.add("measured-chain", req, FAIL if problems else PASS,
          "; ".join(problems) or f"PCR 4: {shown}; grub measured the kernel (PCR 9) and command line (PCR 8)")

    # PCR 7: which db certificate approved the first-stage loader.
    # Each authority event holds one EFI_SIGNATURE_DATA: owner GUID + certificate.
    authorities = [variable_event(d) for pcr, t, d in events if pcr == 7 and t == EV_EFI_VARIABLE_AUTHORITY]
    db = [common_name(value[16:]) for name, value in authorities if name == "db"]
    req = "Measured boot: firmware verified shim"
    if db:
        r.add("measured-authority", req, PASS, f"firmware approved shim with db: {', '.join(db)}")
    else:
        r.add("measured-authority", req, WARN,
              "no db authority event in PCR 7: the firmware either didn't verify shim "
              "(e.g. an 'always execute' image policy) or doesn't log it")

    # PCR 7: firmware pre-boot DMA protection.
    actions = [d.rstrip(b"\0").decode(errors="replace") for pcr, t, d in events if pcr == 7 and t == EV_EFI_ACTION]
    if any("DMA Protection Disabled" in a for a in actions):
        r.add("dma-protection", "IOMMU: pre-boot DMA protection", WARN, "firmware logged 'DMA Protection Disabled' (pre-boot DMA protection is off)")
    else:
        r.add("dma-protection", "IOMMU: pre-boot DMA protection", PASS, "firmware didn't report pre-boot DMA protection as disabled")


def out_of_tree_modules():
    """Loaded modules whose own taint flags include O (out-of-tree)."""
    found = []
    for m in sorted(os.listdir("/sys/module")):
        # Built-in modules have no `taint`; /sys/module also holds plain files.
        taint = f"/sys/module/{m}/taint"
        if os.path.isfile(taint) and "O" in read(taint):
            found.append(m)
    return found


def check_kernel(r, args):
    req = "Signed kernel and modules (well-known keys)"
    release = os.uname().release
    tainted = int((read("/proc/sys/kernel/tainted") or "0").strip())
    problems, notes = [], []
    if args.kernel_release and release != args.kernel_release:
        problems.append(f"running {release}, expected the vendor kernel {args.kernel_release}")

    # Who signed the running kernel's image.
    blobs = authenticode(args.kernel)
    if blobs is None:
        problems.append(f"can't read the kernel image at {args.kernel}")
    elif not blobs:
        problems.append("the kernel image is not signed")
    else:
        signer = next((w for w in map(well_known, blobs) if w), None)
        if signer is None:
            cns = sorted({n for b in blobs for n in names(b)})
            problems.append(f"the kernel is signed by {', '.join(cns) or '?'}, none of them well-known")
        else:
            notes.append(f"kernel signed under '{signer}'")
    # The copy grub loaded from the ESP has to be that same image.
    # grub writes BOOT_IMAGE=(hd0,gpt1)/EFI/...: drop its device prefix.
    m = re.search(r"\bBOOT_IMAGE=(?:\([^)]*\))?(\S+)", read("/proc/cmdline") or "")
    if m and args.esp and blobs:
        booted = os.path.join(args.esp, m.group(1).lstrip("/"))
        try:
            loaded = read(booted, "rb")
        except PermissionError:
            loaded = None
        if loaded is None:
            notes.append(f"couldn't read {booted} to compare it with the running kernel")
        elif loaded != read(args.kernel, "rb"):
            problems.append(f"{booted}, which grub loaded, differs from {args.kernel}")
        else:
            notes.append("same image grub loaded from the ESP")

    unsigned = [m for m in sorted(os.listdir("/sys/module"))
                if os.path.isfile(f"/sys/module/{m}/taint") and "E" in read(f"/sys/module/{m}/taint")]
    if unsigned:
        problems.append(f"unsigned modules loaded (taint E): {', '.join(unsigned)}")
    elif tainted & (1 << 13):
        problems.append("an unsigned module was loaded during this boot (taint E; reboot to clear)")
    if tainted & (1 << 12):
        # Without taint E, every loaded module passed signature verification
        # against a key the kernel trusts; the `mok` check covers MOK keys.
        # Epic allows out-of-tree modules (NVIDIA's named) built by an
        # organization and signed with a well-known key.
        # The taint stays after a module unloads (or fails to initialise).
        loaded = out_of_tree_modules()
        notes.append(f"vendor-signed out-of-tree modules: {', '.join(loaded)}" if loaded
                     else "a vendor-signed out-of-tree module was loaded earlier this boot")
    if problems:
        return r.add("signed-kernel", req, FAIL, "; ".join(problems))
    r.add("signed-kernel", req, PASS, f"{release}, no unsigned modules" + "".join(f"; {n}" for n in notes))


def check_lockdown(r):
    req = "Kernel lockdown (integrity)"
    mode = read("/sys/kernel/security/lockdown")
    if mode is None:
        return r.add("lockdown", req, FAIL, "lockdown LSM not available")
    active = re.search(r"\[(\w+)\]", mode).group(1)
    r.add("lockdown", req, PASS if active in ("integrity", "confidentiality") else FAIL, f"lockdown: {active}")


def check_kexec(r):
    value = (read("/proc/sys/kernel/kexec_load_disabled") or "").strip()
    if not value:
        return r.add("kexec", "kexec disabled", PASS, "no kexec_load_disabled sysctl: the kernel has no kexec")
    r.add("kexec", "kexec disabled", PASS if value == "1" else FAIL, f"kernel.kexec_load_disabled = {value}")


def check_bpf_lsm(r):
    lsms = (read("/sys/kernel/security/lsm") or "").strip().split(",")
    r.add("bpf-lsm", "BPF LSM loaded and active", PASS if "bpf" in lsms else FAIL, f"active LSMs: {','.join(lsms)}")


def handheld():
    """Whether this is a handheld, the way Bazzite's check-anticheat tells.

    Epic requires the IOMMU only "on non-handheld devices" without defining
    them. Bazzite counts Valve hardware and SMBIOS chassis types 30-32
    (tablet, convertible, detachable), which is how handhelds report.
    """
    vendor = (read("/sys/class/dmi/id/sys_vendor") or "").strip()
    chassis = (read("/sys/class/dmi/id/chassis_type") or "").strip()
    return vendor == "Valve" or chassis in ("30", "31", "32")


def check_iommu(r):
    req = "IOMMU on, passthrough off (non-handheld)"
    if handheld():
        return r.add("iommu", req, PASS, "handheld (Valve hardware or chassis type 30-32): not required")
    cmdline = (read("/proc/cmdline") or "").split()
    forced = [a for a in cmdline if a in ("iommu=pt", "iommu=off", "iommu.passthrough=1",
                                          "amd_iommu=pt", "amd_iommu=off", "intel_iommu=off")]
    hint = f" (kernel command line: {' '.join(forced)})" if forced else ""
    iommus = os.listdir("/sys/class/iommu") if os.path.isdir("/sys/class/iommu") else []
    if not iommus:
        return r.add("iommu", req, FAIL, f"no IOMMU is active{hint}")
    groups = "/sys/kernel/iommu_groups"
    identity = []
    total = 0
    for g in sorted(os.listdir(groups), key=int):
        total += 1
        if (read(f"{groups}/{g}/type") or "").strip() == "identity":
            for dev in os.listdir(f"{groups}/{g}/devices"):
                base = f"{groups}/{g}/devices/{dev}"
                driver = os.path.basename(os.readlink(f"{base}/driver")) if os.path.exists(f"{base}/driver") else "-"
                identity.append(f"group {g}: {dev} ({driver})")
    if forced:
        return r.add("iommu", req, FAIL, f"passthrough forced{hint}")
    if identity:
        return r.add("iommu", req, WARN,
                     f"{len(identity)} of {total} groups in passthrough (identity) mode: {'; '.join(identity)}. "
                     "Whether EAC counts per-device passthrough is unknown")
    r.add("iommu", req, PASS, f"all {total} IOMMU groups translated")


def check_mok(r, args):
    req = "Only well-known MOKs"
    try:
        data = read(f"{MOK_VARIABLES}/MokListRT", "rb")
    except PermissionError:
        return r.add("mok", req, UNKNOWN, f"{MOK_VARIABLES} is root-only; run as root")
    if data is None:
        data = efivar("MokListRT", SHIM_GUID)
    if data is None:
        return r.add("mok", req, UNKNOWN, "no MokListRT: shim isn't in this boot's chain")
    certs, hashes = signature_lists(data)
    # Certificates eacnix knows byte for byte: shim's own vendor certificate
    # (always in MokListRT) and the vendor path's MOKs (Bazzite: Universal
    # Blue's). Anything else passes only if it names a well-known authority.
    exact = [read(path, "rb") for path in [args.vendor_cert, *args.well_known_mok] if path]
    verified, by_name, unknown = [], [], []
    for c in certs:
        if c in exact:
            verified.append(common_name(c))
        elif well_known(c):
            by_name.append(common_name(c))
        else:
            unknown.append(common_name(c))
    if unknown:
        return r.add("mok", req, FAIL,
                     f"not well-known: {', '.join(unknown)}. Export them with 'mokutil --export', "
                     "then remove each with 'sudo mokutil --delete MOK-000N.der'")
    detail = f"verified: {', '.join(verified) or 'none'}"
    if by_name:
        detail += f"; well-known by name only (not checked byte for byte): {', '.join(by_name)}"
    if hashes:
        # The kernel ignores hashes in MokList (it loads only X.509 MOKs), so
        # they don't affect module signing; they let shim boot specific
        # binaries. Epic's rule names keys, so how EAC treats them is unknown.
        return r.add("mok", req, WARN,
                     f"{detail}; {hashes} image hash(es) enrolled, which let shim boot specific binaries. "
                     "Whether EAC accepts MOK hashes is unknown")
    r.add("mok", req, PASS, detail)


# --- main ----------------------------------------------------------------------


SYMBOL = {PASS: "✓", WARN: "!", FAIL: "✗", UNKNOWN: "?"}


def main():
    p = argparse.ArgumentParser(prog="eacnix-check", description=__doc__.split("\n\n")[0])
    p.add_argument("--dir", default="eacnix", help="eacnix's directory under <ESP>/EFI")
    p.add_argument("--kernel-release", help="the vendor kernel's `uname -r`")
    p.add_argument("--kernel", default="/run/booted-system/kernel", help="the running kernel's image")
    p.add_argument("--esp", help="the ESP's mount point, to compare the kernel grub loaded")
    p.add_argument("--vendor-cert", help="DER certificate embedded in the vendor shim")
    p.add_argument("--well-known-mok", action="append", default=[], metavar="DER",
                   help="a well-known MOK certificate the vendor path needs (repeatable)")
    p.add_argument("--json", action="store_true", help="print results as JSON")
    args = p.parse_args()

    r = Report()
    check_boot_path(r, args)
    check_secure_boot(r)
    check_tpm(r)
    check_event_log(r, args)
    check_kernel(r, args)
    check_lockdown(r)
    check_kexec(r)
    check_bpf_lsm(r)
    check_iommu(r)
    check_mok(r, args)

    if args.json:
        print(json.dumps(r.results, indent=2))
    else:
        width = max(len(x["requirement"]) for x in r.results)
        for x in r.results:
            print(f"{SYMBOL[x['status']]} {x['status']:<8}{x['requirement']:<{width}}  {x['detail']}")
        print("\nThese are Epic's published requirements; EAC itself may check more.")
    sys.exit(1 if any(x["status"] == FAIL for x in r.results) else 0)


if __name__ == "__main__":
    main()
