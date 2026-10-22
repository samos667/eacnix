# eacnix

eacnix is a NixOS module that adds a boot path meeting the requirements of
Easy Anti-Cheat Linux v2. It boots your NixOS system on **Fedora's or
Bazzite's signed kernel**, through Fedora's Microsoft-signed shim and
Fedora-signed grub, as a separate boot entry next to your normal one.

Your userspace, configuration, and generations stay NixOS. Only the kernel,
its modules, and the boot chain come from a distribution whose signing key
EAC trusts. Nothing in that chain is built or signed locally.

## Status

The first milestone is done. You can use eacnix today if your machine:

- is x86_64 with UEFI, Secure Boot, and a TPM 2.0;
- boots NixOS with **systemd-boot** or **lanzaboote** (detected
  automatically);
- uses **no locally built kernel modules** on the eac path (ZFS from
  nixpkgs, `xone`, and similar; see [Limitations](#limitations)). NVIDIA GPUs
  work with `eacnix.vendor = "bazzite"` and `eacnix.nvidia.enable`, which
  use Universal Blue's signed builds of NVIDIA's modules: the open ones for
  Turing and newer (tested in VMs without a GPU so far). For pre-Turing GPUs
  (Maxwell, Pascal, Volta) there's limited support for the proprietary
  modules; see [Limitations](#limitations).

What works:

- Fedora's (default) or Bazzite's signed kernel and modules, with Fedora's
  shim and grub, packaged byte-for-byte from Fedora's build system or
  Universal Blue's images and pinned by hash (`eacnix.vendor`). Bazzite is
  tested in VMs only so far.
- An `eac` specialisation of each generation, running NixOS on that kernel
  with every requirement in [Epic's list](#how-each-requirement-is-met)
  applied.
- A separate firmware boot entry, a one-shot `eac-reboot`, and rollback across
  the last few generations.
- `eacnix-check`, which checks the running system against each published
  requirement, using the TPM event log.
- VM tests under Secure Boot with a TPM, and one real machine verified (see
  [Verification](#verification)).

EAC v2 isn't released yet. Everything here is built against Epic's
**published** requirements; whether EAC accepts this setup is
[an open question](#questions-for-epic).

## How it works

```
firmware ──► shim (Microsoft-signed) ──► grub (Fedora-signed) ──► kernel (vendor-signed)
                                                                      │
                                              initrd + userspace ◄────┘
                                              (NixOS, measured)
```

With Secure Boot on, the firmware checks shim against Microsoft's certificate
in `db`. shim checks grub and Fedora's kernel against Fedora's certificate,
and Bazzite's kernel against Universal Blue's, enrolled as a MOK. The kernel
loads only modules signed by its own build key or, on Bazzite, by Universal
Blue's MOK, and lockdown stops even root from changing kernel memory.

The initrd, the kernel command line, and userspace are **measured but not
signed**, on every distribution: Fedora and Bazzite build their initrd on
each machine, so its hash is different everywhere. The trust chain that EAC's
requirements describe therefore ends at a signed kernel in lockdown. A NixOS
userspace sits on top of that kernel exactly like any other distribution's
userspace.

Epic's announcement explicitly allows "a separate, compliant boot entry just
for protected games". eacnix is that entry. Your normal NixOS entry is not
changed.

## How each requirement is met

| Epic's requirement                               | On the eac path                                                                                                                                                                                 |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signed kernel and modules, using well-known keys | The vendor's kernel and modules, byte-for-byte. Fedora and Universal Blue are on the published list of trusted keys. Locally built modules are rejected at build time.                          |
| TPM 2.0                                          | Required hardware.                                                                                                                                                                              |
| UEFI Secure Boot                                 | Fedora's shim (signed by the Microsoft UEFI CA) and grub, with the firmware's stock keys.                                                                                                       |
| Measured boot                                    | The firmware measures shim and grub (PCR 4); grub measures the kernel, initrd, and command line (PCR 8/9).                                                                                      |
| IOMMU on, passthrough off                        | `intel_iommu=on`, `iommu.passthrough=0` (AMD's IOMMU is on by default).                                                                                                                         |
| Kernel lockdown, integrity mode                  | eacnix passes `lockdown=integrity`. Fedora's kernel also locks down under Secure Boot on its own; Bazzite's doesn't.                                                                            |
| kexec disabled                                   | `kernel.kexec_load_disabled = 1`.                                                                                                                                                               |
| BPF LSM loaded and active                        | NixOS always includes `bpf` in `security.lsm`; eacnix asserts it stays there.                                                                                                                   |
| No self-enrolled MOK                             | Epic requires every enrolled MOK to be well-known. Fedora needs none; Bazzite needs Universal Blue's, which is on Epic's list. `eacnix-check` verifies that shim's MOK list holds nothing else. |

## Getting started

Add the flake and enable the module:

```nix
# flake.nix
{
  inputs.eacnix.url = "git+https://<repository URL>";

  outputs = { nixpkgs, eacnix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        eacnix.nixosModules.default
        {
          eacnix.enable = true;
          # Optional: boot Bazzite's kernel instead of Fedora's.
          # eacnix.vendor = "bazzite";
          # Optional: list "NixOS EAC" in the firmware's boot menu.
          eacnix.boot.addToBootOrder = true;
        }
        # ...
      ];
    };
  };
}
```

Your configuration needs systemd-boot or lanzaboote, and
`boot.loader.efi.canTouchEfiVariables = true` so eacnix can create its
firmware boot entry. With lanzaboote, keep Microsoft's keys enrolled next to
yours (`autoEnrollKeys.includeMicrosoftKeys`, or `sbctl enroll-keys
--microsoft`): the vendor's shim is signed by Microsoft.

With `eacnix.vendor = "bazzite"`, enroll Universal Blue's certificate once
before booting the eac path with Secure Boot on: run `sudo eacnix-enroll-mok`
(it asks for a one-time password), then `sudo eac-reboot`, and in the blue
MokManager screen choose "Enroll MOK" and enter that password. It's the same
key Bazzite itself asks you to enroll. A MOK is trusted by every boot entry
on the machine, not just the eac one.

After `nixos-rebuild switch`:

```sh
sudo eac-reboot     # boot the eac path once; the next reboot returns to normal
sudo eacnix-check   # on the eac path: check every requirement
```

If you set `addToBootOrder`, you can also pick "NixOS EAC" in the firmware's
boot menu. Either way, the eac path never becomes your default: eacnix only
adds its entry behind another OS entry. On a fresh lanzaboote install, which
boots through the firmware's fallback path, that entry appears after the
first boot, and the next rebuild adds "NixOS EAC" behind it.

### Firmware settings

eacnix can't change firmware settings, and some boards ship with settings
that undermine the requirements. `eacnix-check` warns about both of these:

- **Secure Boot must actually verify images.** Some firmware reports Secure
  Boot as enabled but runs unsigned images anyway (on MSI boards, an "Image
  Execution Policy" of "Always Execute"). Then no `db` approval for shim
  appears in the TPM log. Set the policy for fixed disks to deny images that
  fail verification. A plain systemd-boot entry is unsigned, so it won't boot
  under a strict policy; lanzaboote's will. See
  [Your normal entry](#your-normal-entry).
- **Pre-boot DMA protection** should be enabled, if your firmware has the
  option.

Keep Microsoft's certificates enrolled. Fedora's shim and most GPU option
ROMs depend on them. Fedora's shim is signed by both the 2011 and the 2023
Microsoft UEFI CA.

## Options

| Option                         | Default                  | Description                                                                                                                                                                                                                   |
| ------------------------------ | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `eacnix.enable`                | `false`                  | Add the eac boot path.                                                                                                                                                                                                        |
| `eacnix.vendor`                | `"fedora"`               | Whose signed kernel to boot: `"fedora"` or `"bazzite"` (needs Universal Blue's MOK).                                                                                                                                          |
| `eacnix.nvidia.enable`         | `false`                  | On the eac path, use Universal Blue's signed NVIDIA modules and NVIDIA's userspace of the same version. Needs `eacnix.vendor = "bazzite"` and NVIDIA enabled in `services.xserver.videoDrivers`.                              |
| `eacnix.nvidia.flavor`         | `"open"`                 | `"open"` (615 branch, Turing and newer) or `"proprietary"` (580 branch), only for pre-Turing GPUs (Maxwell, Pascal, Volta), with limited support. `"proprietary"` uses Bazzite's LTS kernel, like the `bazzite-nvidia` image. |
| `eacnix.bazzite.kernel`        | from `nvidia.flavor`     | `"ogc"` (Bazzite's current kernel) or `"ogc-lts"` (its LTS kernel, 6.18).                                                                                                                                                     |
| `eacnix.mode`                  | `"specialisation"`       | `"specialisation"` adds an `eac` variant of each generation. `"system"` runs the vendor's kernel on the normal system too.                                                                                                    |
| `eacnix.boot.install`          | `true`                   | Install the eac boot path after the bootloader's own install (systemd-boot or lanzaboote).                                                                                                                                    |
| `eacnix.boot.directory`        | `"eacnix"`               | eacnix's directory under `<ESP>/EFI`.                                                                                                                                                                                         |
| `eacnix.boot.generations`      | `3`                      | eac generations kept on the ESP, for rollback.                                                                                                                                                                                |
| `eacnix.boot.timeout`          | `3`                      | grub menu timeout, in seconds.                                                                                                                                                                                                |
| `eacnix.boot.label`            | `"NixOS EAC"`            | Name of the firmware boot entry.                                                                                                                                                                                              |
| `eacnix.boot.addToBootOrder`   | `false`                  | Append the entry to BootOrder so the firmware's boot menu lists it. eacnix only appends, and only behind another OS entry: it never reorders or removes entries.                                                              |
| `eacnix.boot.hideFromBootMenu` | `true`                   | Remove the `eac` specialisation from the boot menu (the entries systemd-boot or lanzaboote write for it). Booting it from there would put the bootloader in the measured chain instead of shim and grub.                      |
| `eacnix.kconfigServices`       | scx services, if enabled | Services that need the vendor's kernel config at `/boot/config-<release>` (libbpf).                                                                                                                                           |

### ESP usage

eacnix writes only to `<ESP>/EFI/eacnix/` (and, with `hideFromBootMenu`,
removes the entries systemd-boot or lanzaboote write for the eac
specialisation). Generations that share a kernel or
initrd share one copy, so expect about 50 MiB, and up to about 135 MiB with
three generations that all have a different kernel. Each install checks free
space before writing anything. If the ESP is full, nothing new is installed,
the existing eac entries keep working, and `nixos-rebuild` prints a warning
without failing.

## Verification

`sudo eacnix-check` reports each published requirement as pass, warn, fail, or
unknown (`--json` for scripts), using the kernel, the EFI variables, and the
TPM event log:

| Check                | What it looks at                                                                                                                                                                                                            |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `boot-path`          | The firmware started eacnix's shim, grub loaded the kernel.                                                                                                                                                                 |
| `secure-boot`        | Secure Boot on, in user mode, and shim still validating (not `mokutil --disable-validation`).                                                                                                                               |
| `tpm`                | A TPM 2.0.                                                                                                                                                                                                                  |
| `measured-chain`     | PCR 4 holds only shim → grub (→ kernel); grub measured the kernel and command line.                                                                                                                                         |
| `measured-authority` | The firmware logged which `db` certificate approved shim.                                                                                                                                                                   |
| `dma-protection`     | The firmware didn't log "DMA Protection Disabled".                                                                                                                                                                          |
| `signed-kernel`      | The pinned vendor kernel, signed under a well-known authority, and the same image grub loaded from the ESP; no unsigned module loaded (each one is named). Vendor-signed out-of-tree modules, such as NVIDIA's, are listed. |
| `lockdown`           | Lockdown in integrity (or confidentiality) mode.                                                                                                                                                                            |
| `kexec`              | kexec disabled (or not built into the kernel).                                                                                                                                                                              |
| `bpf-lsm`            | The BPF LSM is active.                                                                                                                                                                                                      |
| `iommu`              | An IOMMU is active and no passthrough is forced on the command line; warns for each device group in passthrough mode. Not required on handhelds (Valve hardware, SMBIOS chassis types 30–32), as Epic exempts them.         |
| `mok`                | Every MOK is well-known: eacnix's own certificates byte for byte, others by authority name (as Bazzite's `ujust check-anticheat` does). Warns if image hashes are enrolled.                                                 |

**Automated tests** (`nix flake check`); `secure-boot-vm` and `kernel-vm` run
once per vendor (`-fedora`, `-bazzite`):

- `secure-boot-vm-*`: firmware with only Microsoft's keys and Secure Boot
  enforcing, a software TPM, the full shim → grub → kernel chain into NixOS.
  `eacnix-check` passes every check except `iommu` (QEMU has no IOMMU). For
  Bazzite, Universal Blue's certificate is put in shim's MOK list.
- `kernel-vm-*`: NixOS on the vendor's kernel. A module with its signature
  stripped is refused under lockdown, and a sched_ext scheduler loads.
- `lanzaboote-vm`: eacnix next to lanzaboote, with the owner's key and
  Microsoft's in `db` and Secure Boot enforcing. lanzaboote's normal entry and
  the eac path both boot, lanzaboote's UKI for the eac specialisation is
  removed, and `eacnix-check` passes every check except `iommu` on the eac
  path.
- `esp-full`: the installer on a nearly full ESP.
- `lanzaboote-vm` runs on Fedora.
- `secure-boot-vm-bazzite` and `secure-boot-vm-bazzite-lts` also run
  `eacnix.nvidia`, open and proprietary: through Universal Blue's MOK, the
  kernel accepts the signed `nvidia.ko` (its init runs and finds no GPU).
  `kernel-vm-bazzite-lts` boots the LTS kernel directly.
- `kernel-tools`: tools such as turbostat and cpupower build for every
  vendor's kernel.

**Hardware** (Fedora; Bazzite hasn't been run on hardware yet): an MSI MAG X870 Tomahawk with an AMD CPU and a Radeon RX 7900
GPU passes every check except one warning: the GPU's IOMMU group is in
passthrough mode. The AMD IOMMU driver does this for all PASID-capable devices
until an upstream fix accepted in September 2026 (see
[questions](#questions-for-epic)). Details, including what each PCR held, are
in [docs/findings.md](docs/findings.md).

## Limitations

- **No locally built kernel modules on the eac path.** Anything built
  locally is unsigned, so ZFS from nixpkgs, `v4l2loopback`, `xone`, and
  similar can't load. The build fails and names the NixOS module file that
  added each one, so you can turn that option off for the eac path only.
- **NVIDIA needs Bazzite.** Fedora doesn't ship signed NVIDIA modules.
  Universal Blue ships signed builds of NVIDIA's open modules for Bazzite's
  current kernel (Turing and newer), and of the proprietary 580 modules only
  for its LTS kernel (6.18), so the proprietary driver comes with that
  kernel. GPUs older than Maxwell aren't supported by either. The driver
  version is Universal Blue's, pinned with the kernel, not the one your
  normal system runs.
- **The proprietary NVIDIA driver is only for pre-Turing GPUs, with limited
  support.** Use `eacnix.nvidia.flavor = "proprietary"` only on Maxwell,
  Pascal, or Volta GPUs; anything from Turing on should use the open
  modules. It's tested only in a VM without a GPU (the kernel accepts the
  signed modules), and there's no pre-Turing hardware available to test it
  on, so whether it drives a real GPU, and what EAC makes of it, is
  unverified. Reports from pre-Turing users are welcome.
- **No kernel customisation on the eac path:** `boot.kernelPatches`, custom
  kernel configs, and `boot.kernel.features` don't apply.
- **Hibernation is blocked** by lockdown.
- **The kernel follows the vendor's releases.** The pinned kernel, grub, and
  shim must be bumped together, especially when the vendor ships security
  fixes or revokes old boot components. Bazzite's kernel is fetched from
  ghcr.io, which prunes old images after a few months: an old pin stops being
  fetchable unless it's already in your Nix store or a cache.
- **systemd-boot or lanzaboote.** With another bootloader, eacnix prints the
  `eacnix-boot install` command to run after each switch.
- **Initrd secrets** (`boot.initrd.secrets`) aren't supported on the eac path.
- **The measurements identify the system as NixOS.** grub measures the kernel
  command line, which contains `/nix/store/…-nixos-system-<hostname>-…`.

### Your normal entry

Secure Boot keys are shared by every boot entry, so your normal NixOS entry
has to live with the same firmware settings:

- **Microsoft keys only.** The eac entry works; an unsigned normal entry needs
  Secure Boot off. Setting `eacnix.mode = "system"` runs the vendor's kernel
  all the time, so a single compliant entry is all you need.
- **Your own key next to Microsoft's**, with lanzaboote. Both entries boot
  with Secure Boot enforcing (`checks.lanzaboote-vm` covers this setup). The vendors' kernels use `db` keys only to verify kexec images, which
  is disabled, so your key can't sign anything the eac path loads. Whether EAC
  accepts an extra key in `db` is a [question for Epic](#questions-for-epic).
- **Only well-known MOKs.** The kernels trust MOK keys for module signatures,
  and Epic requires every enrolled MOK to be well-known, whichever entry you
  boot. A key you generated yourself (for DKMS or akmods) fails EAC on every
  entry; Universal Blue's, which the Bazzite path needs, is on Epic's list.

## Questions for Epic

eacnix follows the published requirements. These are the points it can't
settle on its own:

1. **NixOS on another distribution's signed boot chain.** NixOS has no
   central signing key, because users build their own kernels. eacnix boots
   NixOS userspace and initrd on Fedora's or Bazzite's signed kernel, all
   measured. Is that an accepted (or intended) route for distributions like
   NixOS, or should NixOS aim for its own entry when Epic opens the
   trusted-key list to community additions? Does EAC look at the distribution
   identity (`os-release`, the measured kernel command line)?
2. **An extra `db` key.** Is a boot accepted when `db` also holds the owner's
   own certificate next to Microsoft's, if the measured chain was approved by
   the Microsoft UEFI CA?
3. **Per-device IOMMU passthrough.** Does "IOMMU passthrough disabled" refer
   to the kernel's default domain type, or to every IOMMU group? Until a
   recent upstream fix, the AMD IOMMU driver puts every PASID-capable device,
   including current AMD GPUs, in an identity (passthrough) domain even with
   `iommu.passthrough=0`. Kernels before the fix will show this on most AMD
   systems (details in [docs/findings.md](docs/findings.md)).
4. **Delivery.** How will the EAC v2 service be delivered, and what does it
   expect from the filesystem layout?
5. **MOK hashes.** shim's MOK list can hold image hashes as well as keys. The
   kernel ignores them for module signing; they only let shim boot those
   exact binaries. Does "every enrolled MOK must be well-known" cover them?
6. **Handhelds.** The IOMMU requirement applies "on non-handheld devices".
   How does EAC tell a handheld? eacnix follows Bazzite's check: Valve
   hardware or SMBIOS chassis types 30–32.

## Development

```
flake.nix                        nixosModules.default, packages, checks
modules/eacnix.nix               the NixOS module
pkgs/vendor-kernel.nix           a vendor's signed kernel and modules as a NixOS kernel
pkgs/<vendor>/sources.nix        pinned URLs and hashes (Koji, ghcr.io)
pkgs/<vendor>/kernel.nix         unpacks the vendor's packages for vendor-kernel.nix
pkgs/<vendor>/kernel-config      vendored from the package, checked at build time
pkgs/<vendor>/kernel-modules.list  module names and aliases, checked at build time
pkgs/fedora/boot-chain.nix       signed shimx64.efi, mmx64.efi, grubx64.efi (Bazzite uses them too)
pkgs/bazzite/nvidia.nix          Universal Blue's signed NVIDIA modules and matching userspace
pkgs/eacnix-boot/                ESP installer, firmware entry, BootNext
pkgs/eacnix-check/               compliance check
tests/                           NixOS VM tests
docs/findings.md                 artifact analysis and measurement results
```

```sh
nix build .#fedora-kernel .#fedora-boot-chain .#bazzite-kernel .#bazzite-lts-kernel .#eacnix-boot .#eacnix-check
nix flake check -L
```

To bump a vendor (`fedora` or `bazzite`):

1. Update `pkgs/<vendor>/sources.nix`. For Fedora: kernel, grub, and shim
   together. For Bazzite, per kernel flavour: take
   the kernel from the `ostree.linux` label of a current `bazzite` image
   (`ogc`) or `bazzite-nvidia` image (`ogc-lts`), pin the layers of
   `ghcr.io/ublue-os/akmods:<flavour>-<fedora>-<kernel>` and of
   `akmods-nvidia-open` (`ogc`) or `akmods-nvidia-lts` (`ogc-lts`) with the
   same tag, and set NVIDIA's userspace hashes for the version of its
   `kmod-nvidia`.
2. Run `nix build .#<vendor>-kernel.vendored && cp result/* pkgs/<vendor>/`
   (for Bazzite: `.#bazzite-kernel` into `pkgs/bazzite/ogc/`,
   `.#bazzite-lts-kernel` into `pkgs/bazzite/ogc-lts/`).
3. Run `nix flake check`.

## Sources

- [Epic: Introducing Easy Anti-Cheat Linux v2](https://onlineservices.epicgames.com/news/introducing-easy-anti-cheat-linux-v2)
- [The FPS Review: requirements, trusted keys, MOK, separate boot entry](https://www.thefpsreview.com/2026/10/15/fortnite-is-coming-to-linux-via-easy-anti-cheat-linux-v2-which-needs-secure-boot-tpm-2-0-and-signed-kernels-steam-deck-isnt-supported-yet/)
- [Phoronix: systemd service and eBPF architecture](https://www.phoronix.com/news/Easy-Anti-Cheat-Better-Linux)
