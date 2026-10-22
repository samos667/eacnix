# Pinned Bazzite artifacts. Bazzite takes its kernel and signed kmods from
# Universal Blue's akmods images on ghcr.io: the Open Gaming Collective
# ("ogc") kernel, re-signed by Universal Blue, with the kernel RPMs under
# /kernel-rpms. Bazzite builds two kernel flavours: `ogc` for most images
# (and `-nvidia-open`), and `ogc-lts` for `bazzite-nvidia`, whose proprietary
# NVIDIA modules Universal Blue builds only for the LTS kernel.
#
# Bump each flavour to the kernel of a current Bazzite image (its
# `ostree.linux` label: `bazzite` for ogc, `bazzite-nvidia` for ogc-lts),
# then refresh ./<flavour>/kernel-config and kernel-modules.list (see
# ../vendor-kernel.nix).
#
# Each image has a single layer. It's fetched by its OCI digest, which is
# also its sha256, so the pin is exactly the layer Bazzite's build uses.
# ghcr.io serves public blobs to any bearer token; "QQ==" is the usual
# placeholder. ghcr.io prunes old akmods tags after a few months, so an old
# pin stops being fetchable unless it's already in a Nix store or cache.
let
  layer = repo: digest: {
    url = "https://ghcr.io/v2/ublue-os/${repo}/blobs/sha256:${digest}";
    curlOptsList = [
      "-H"
      "Authorization: Bearer QQ=="
    ];
    sha256 = digest;
  };
in
{
  release = "44";

  # Bazzite stable 44.20261012.1 (ghcr.io/ublue-os/bazzite:stable@sha256:5d49529c…).
  ogc = rec {
    flavor = "ogc";
    kernel = rec {
      version = "7.2.9";
      release = "ogc3.1.fc44";
      modDirVersion = "${version}-${release}.x86_64";
      # Vanilla source of the same upstream version, for kernelPackages tools.
      upstream = {
        url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
        hash = "sha256-tMXfvlGjZKbH8DhpIA+IyOH3dANTkAXxS3/GvJG42Lo=";
      };
      # ghcr.io/ublue-os/akmods:ogc-44-${modDirVersion}
      # @sha256:eb2de16215cbbd38bca0b1929bbfac1b157312655cfa7e138d8d213fe077ef5e
      akmods = layer "akmods" "e0282fd2bba3dd1f386c791c40c1d57b0dcc2b49586653a1a62659cb5859f7db";
    };

    # Universal Blue's builds of NVIDIA's open kernel modules for this kernel,
    # signed with the same MOK, and NVIDIA's userspace at the exact same
    # version (the driver refuses modules of another version).
    nvidia = rec {
      proprietary = false;
      version = "615.78.08";
      # ghcr.io/ublue-os/akmods-nvidia-open:ogc-44-${kernel.modDirVersion}
      # @sha256:c94ae195e720e52ccab0e9e1c1261081613b621d64d58018f6d03c0a0e2ad1c1
      akmods = layer "akmods-nvidia-open" "29f0ea644b7095f517f0f2643f8d5a1ceaba3797f3063dee800d680be7ee2406";
      kmod = "kmod-nvidia-${kernel.modDirVersion}-${version}-1.fc44.x86_64.rpm";
      # nixpkgs' nvidiaPackages.mkDriver arguments (nixpkgs' new_feature).
      userspace = {
        inherit version;
        sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
        settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
        persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
      };
    };
  };

  # Bazzite stable 44.20261012.1, NVIDIA image
  # (ghcr.io/ublue-os/bazzite-nvidia:stable@sha256:3d13e825…).
  ogc-lts = rec {
    flavor = "ogc-lts";
    kernel = rec {
      version = "6.18.56";
      release = "ogc1.1.fc44";
      modDirVersion = "${version}-${release}.x86_64";
      upstream = {
        url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${version}.tar.xz";
        hash = "sha256-RjO72iq5Xq8qevQEEjZFHWdZxy5pRiZVMa9LOqzvv4k=";
      };
      # ghcr.io/ublue-os/akmods:ogc-lts-44-${modDirVersion}
      # @sha256:a728c03d80b502817db6b02a5606c48be9052d294995b9e0e2611e144d6f86e6
      akmods = layer "akmods" "1a9a53044f2894f03abbcada7773569b5c664ec1728a9be637f0982959c0cf60";
    };

    # Universal Blue's builds of NVIDIA's proprietary kernel modules (the 580
    # branch, the last to support Maxwell, Pascal, and Volta), signed with
    # the same MOK, and NVIDIA's userspace at the exact same version.
    nvidia = rec {
      proprietary = true;
      version = "580.178.04";
      # ghcr.io/ublue-os/akmods-nvidia-lts:ogc-lts-44-${kernel.modDirVersion}
      # @sha256:5503b8fa2b2f3496b1803a17d826ba6b345e387911f31e576ba4fc9b9f4af3f3
      akmods = layer "akmods-nvidia-lts" "f0549d5ff20bf3bb264fd89a8dff98ab88cc1e6598ad81800097b7af1fac7e23";
      kmod = "kmod-nvidia-${kernel.modDirVersion}-${version}-1.fc44.x86_64.rpm";
      # nixpkgs' nvidiaPackages.mkDriver arguments (nixpkgs' legacy_580).
      userspace = {
        inherit version;
        sha256_64bit = "sha256-WXWobuRb/8tib1GuM9EWmxCBhqLqR61lHnLxP6S21vk=";
        settingsSha256 = "sha256-KcrGHoR+ZMdsFyI4myU8/eVls2f8GkNSX/j2JnZndyM=";
        persistencedSha256 = "sha256-3Omj160wtWdKAZDzWt/m/cbUTQ9DMJ1rSxMrnIrKXiw=";
      };
    };
  };
}
