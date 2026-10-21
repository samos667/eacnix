# Pinned Fedora artifacts. Bump kernel, grub and shim together, from the same
# release, and refresh ./kernel-config from the new kernel-core RPM.
let
  koji = "https://kojipkgs.fedoraproject.org/packages";
in
{
  release = "fc45";

  kernel = rec {
    version = "7.2.11";
    release = "300.fc45";
    modDirVersion = "${version}-${release}.x86_64";
    # Vanilla source of the same upstream version. Userspace tools in
    # kernelPackages (turbostat, cpupower, perf, ...) build from `kernel.src`;
    # Fedora's patches don't matter to them, and the kernel itself never
    # builds from this.
    upstream = {
      url = "https://cdn.kernel.org/pub/linux/kernel/v${builtins.head (builtins.splitVersion version)}.x/linux-${version}.tar.xz";
      hash = "sha256-/Q/EefmDqMBTE/E+nDYzD+ZlHPclOWdIxA1c2T+h5qQ=";
    };
    rpms = {
      core = {
        url = "${koji}/kernel/${version}/${release}/x86_64/kernel-core-${modDirVersion}.rpm";
        hash = "sha256-q2glxtV9vuJXDrKxUGCE5RFAXYssOfvWbmJwKLqVlV4=";
      };
      modules-core = {
        url = "${koji}/kernel/${version}/${release}/x86_64/kernel-modules-core-${modDirVersion}.rpm";
        hash = "sha256-uHs7H9mxWbDLInlO9+jE0x1HgFjWjlwN0IQh3SyXizY=";
      };
      modules = {
        url = "${koji}/kernel/${version}/${release}/x86_64/kernel-modules-${modDirVersion}.rpm";
        hash = "sha256-MJ17DiZm8q8PbhJzeiLQPZ3TTj922bepN55mt0dzJg4=";
      };
    };
  };

  grub = rec {
    version = "2.12";
    release = "81.fc45";
    rpm = {
      url = "${koji}/grub2/${version}/${release}/x86_64/grub2-efi-x64-${version}-${release}.x86_64.rpm";
      hash = "sha256-MNK3sowzjbOcunL4gRLe/NMrz/n18c5FT8FCA2hZnp0=";
    };
  };

  shim = rec {
    version = "16.1";
    release = "7";
    rpm = {
      url = "${koji}/shim/${version}/${release}/x86_64/shim-x64-${version}-${release}.x86_64.rpm";
      hash = "sha256-ChGfNIjl2ifKVcGGTujhMa+l7PJ2iThboJuAXrAN1gg=";
    };
  };
}
