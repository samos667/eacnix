# Findings

Evidence behind the design in the [README](../README.md): what the pinned
Fedora artifacts contain, what the TPM measured in the VM tests and on real
hardware, and the analysis of Fedora's signed grub. Every entry says how it
was obtained and when.

## Pinned Fedora 45 artifacts

`pkgs/fedora/sources.nix` pins kernel `7.2.11-300.fc45`, grub `2.12-81.fc45`,
and shim `16.1-7` from Fedora's Koji. They were inspected on 2026-10-21.

- **shim** (`shimx64.efi`) is signed by Microsoft (Windows UEFI Driver
  Publisher, UEFI CA 2011, UEFI CA 2023 signer, UEFI CA 2023), so it boots on
  firmware that trusts either the 2011 or the 2023 CA.
  - Its `.vendor_cert` is `fedoraca` (Fedora Secure Boot CA 20200709), valid
    until 2037. It has no vendor dbx.
  - SBAT: `shim,4`.
- **grub** is signed twice during Fedora's CA rotation: by
  `fedora-signer-20250530` (Fedora Secure Boot CA 20250530) and by
  `kernel-signer` (`fedoraca`). shim accepts the second.
- **vmlinuz** is signed by `kernel-signer` (`fedoraca`).
- **Modules (4752)** are signed with PKCS#7/SHA-512 by "Fedora kernel signing
  key", a per-build key built into that build's kernel, so they only load on
  the exact `vmlinuz` they came with. They're xz-compressed after signing, so
  the signature sits inside the `.ko.xz`. The RPMs don't include
  `modules.dep`; the package runs `depmod`, which only writes index files.
- The packaged outputs are byte-identical to the RPM contents: `bzImage`, all
  4752 modules, `shimx64.efi`, `mmx64.efi`, and `grubx64.efi`.

## Measured boot in the Secure Boot VM test

`checks.secure-boot-vm`, run on 2026-10-21 under OVMF with a generated PK,
Microsoft's KEK and db, and swtpm. `tpm2_eventlog` showed:

| PCR | What was measured |
|---|---|
| 4 | Three EFI applications only: `\EFI\eacnix\shimx64.efi`, `\EFI\eacnix\grubx64.efi`, then the kernel (loaded by grub through shim). |
| 7 | Secure Boot state, PK, KEK, db, and dbx. A `db` authority event for shim, plus shim's `SbatLevel` and its vendor certificate (`MokListRT`). |
| 8 | Every grub command (`grub_cmd: …`), including the full `kernel_cmdline` with `init=/nix/store/…/init`. |
| 9 | Files grub read: `grub.cfg`, the BLS entry, the kernel, and the initrd. |
| 14 | shim's `MokList`, `MokListX`, and `MokListTrusted` (all empty). |

Without Secure Boot, grub loads the kernel itself instead of through shim, so
PCR 4 has no kernel event and PCR 9 is what records the kernel.

The kernel logs "locked down from command line" rather than "from EFI Secure
Boot", because the module's `lockdown=integrity` takes effect first. The
result is the same.

The test needs two boots. make-disk-image boots its builder kernel through the
same OVMF, so the image can't be built with Secure Boot on. The test boots
once without it, enrolls the keys into the VM's variable store with
`virt-fw-vars`, and boots again.

## Hardware: MSI MAG X870 Tomahawk WIFI

BIOS 1.A92, AMD CPU, Radeon RX 7900-series GPU (Navi 31). Fedora 7.2.11-300.fc45 booted via
`eac-reboot` on 2026-10-21. EAC version: not released. Hardware-verified from
the TPM event log and sysfs, and with `sudo eacnix-check`.

- **Boot path:** `BootCurrent` was "NixOS EAC" (`\EFI\eacnix\shimx64.efi`),
  `LoaderInfo` was `GRUB 2.12`, and `BootNext` was consumed while `BootOrder`
  stayed unchanged.
- **PCR 4:** `\EFI\eacnix\shimx64.efi` → `\EFI\eacnix\grubx64.efi` → the
  kernel, as in the VM.
- **PCR 8/9:** grub's commands, `grub.cfg`, the BLS entry, the kernel, the
  initrd, and the kernel command line. The command line contains
  `init=/nix/store/…-nixos-system-<hostname>-…/init`, so the hostname and the
  fact that this is NixOS are visible in the measurements.
- **Keys:** stock MSI factory keys. PK is `MSI SHIP PK`; KEK holds Microsoft's
  2011 and 2023 KEKs and `MSI SHIP KEK`; `db` holds Microsoft's Windows PCA
  2011, UEFI CA 2011 and 2023, Option ROM CA 2023, and `MSI SHIP DB`; `dbx`
  holds 431 hashes.
- **MOK:** `MokListRT` holds only `fedoraca`. `eacnix-check` compared it byte
  for byte with the certificate in the pinned shim.
- **Lockdown, kexec, BPF LSM, Secure Boot (user mode), TPM 2.0:** all pass.
- **Firmware settings matter.** With the board's initial settings,
  `eacnix-check` warned twice:
  - no `db` authority event for shim in PCR 7. The firmware's Image
    Execution Policy let images run without verification (it also booted an
    unsigned systemd-boot with Secure Boot "enabled");
  - "DMA Protection Disabled" in PCR 7: pre-boot DMA protection was off.

  After changing both in the BIOS, the firmware logged
  `db → Microsoft Corporation UEFI CA 2011` for shim, and the DMA event was
  gone. Both checks pass.
- **Remaining warning, IOMMU:** 37 of 38 IOMMU groups are translated, but the
  GPU's group is in `identity` (passthrough) mode despite
  `iommu.passthrough=0`. This is upstream AMD IOMMU driver behaviour, not
  specific to this machine: `amd_iommu_def_domain_type()` forces an identity
  domain on every PASID-capable device when SME/SNP is off, and recent AMD
  GPUs support PASID (amdgpu uses it for compute). AMD's series
  "iommu/amd: Fix default domain selection for PASID-capable devices"
  (Vasant Hegde) limits forced identity to GPUs with known hardware bugs
  (early Raven/Picasso APUs, Radeon Pro WX 4100), so discrete GPUs get a
  paging domain. It was accepted for linux-next on 2026-09-24; the mainline
  release that carries it isn't confirmed. Fedora 7.2.11 predates it.
  Sources: [series](https://ratatoskr.run/linux-iommu/2026/07/17307944/t),
  [v2 patch](https://ratatoskr.run/linux-iommu/2026/08/17452208/t).

## Fedora's signed grub

From `grub2-efi-x64-2.12-87.fc46.x86_64.rpm` (static analysis on 2026-10-21;
the pinned 2.12-81.fc45 build behaves the same in the VM tests).

- **Embedded config:** none. The image holds only a prefix, `/EFI/fedora`,
  and a memdisk with `fonts/unicode.pf2`. Red Hat's patches (`fw_path`) make
  grub look for `grub.cfg` in the directory it was started from first. The
  Secure Boot VM test confirms this, so eacnix uses `EFI/eacnix/` and doesn't
  collide with a real Fedora install.
- **SBAT:** `grub,5` and `grub.rh,2`.
- **Built-in modules (116).** Under Secure Boot grub can't load modules from
  disk, so this set is all there is. The ones that matter:
  - `tpm`: grub measures the kernel, initrd, and command line into PCR 8/9.
  - `blscfg`, `blsuki`: grub reads BLS entries. Fedora's `blscfg` calls a
    `load_video` function that only Fedora's own `grub.cfg` defines, so
    eacnix's `grub.cfg` defines it too.
  - Filesystems: `fat`, `ext2` (also reads ext4), `btrfs`, `xfs`, `f2fs`,
    `hfsplus`, `iso9660`, `squash4`. No `zfs`.
  - Storage: `luks`, `luks2`, `cryptodisk`, `lvm`, `mdraid09`, `mdraid1x`.
    There is no argon2, so LUKS2 volumes with the default key derivation
    probably can't be unlocked by grub. eacnix keeps kernels on the ESP, so
    this doesn't affect it.

To reproduce the module list, parse the PE `mods` section: a
`grub_module_info64` header followed by module records. Read each ELF module's
`.modname`, plus the prefix, config, and memdisk records.

## Fedora's kernel configuration

From the vendored config (`pkgs/fedora/kernel-config`, 7.2.11-300.fc45):

| Option | Value | Meaning for eacnix |
|---|---|---|
| `CONFIG_LSM` | `"lockdown,yama,integrity,selinux,bpf,landlock,ipe"` | NixOS overrides it with `lsm=` from `security.lsm`, which always includes `bpf`. Lockdown is an early LSM and stays active. |
| `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` | `y` | Lockdown turns on automatically under Secure Boot. |
| `CONFIG_MODULE_SIG`, `CONFIG_MODULE_SIG_ALL` | `y` | Modules are signed; lockdown enforces it (`MODULE_SIG_FORCE` is unset). |
| `CONFIG_INTEGRITY_MACHINE_KEYRING` | `y` | MOK keys are trusted for module signatures, which is why any enrolled MOK breaks the trust chain. |
| `CONFIG_INTEGRITY_PLATFORM_KEYRING`, `CONFIG_LOAD_UEFI_KEYS` | `y` | Firmware `db` keys go to `.platform`, used only for kexec, which is disabled. |
| `CONFIG_KEXEC`, `CONFIG_KEXEC_FILE` | `y` | kexec is built in, so the sysctl is required. |
| `CONFIG_INTEL_IOMMU_DEFAULT_ON` | not set | eacnix passes `intel_iommu=on`. |
| `CONFIG_IKCONFIG` | not set | No `/proc/config.gz`; see `eacnix.kconfigServices`. |
| `CONFIG_SCHED_CLASS_EXT`, `CONFIG_DEBUG_INFO_BTF` | `y` | sched_ext schedulers work. |
