{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.eacnix;
  eacnixPkgs = import ../pkgs { inherit pkgs; };

  # Settings that turn a NixOS system into one booting Fedora's signed kernel
  # with EAC Linux v2's published requirements applied. Each line maps to a
  # row of the requirement table in README.md.
  eacConfig =
    {
      config,
      options,
      lib,
      ...
    }:
    let
      kernel = config.boot.kernelPackages.kernel;
      available = lib.genAttrs kernel.moduleNames (_: null);
      missingModules = lib.filter (m: !(available ? ${lib.replaceStrings [ "-" ] [ "_" ] m}));

      # Which files put unsigned modules in boot.extraModulePackages, so the
      # assertion can point at the option to turn off (e.g. hardware.xone).
      extraModuleSources = lib.concatMapStrings (
        d: "\n  - ${d.file}: ${lib.concatMapStringsSep ", " (p: p.name or "?") d.value}"
      ) (lib.filter (d: d.value != [ ]) options.boot.extraModulePackages.definitionsWithLocations);
    in
    {
      # Signed kernel and modules, using well-known keys.
      boot.kernelPackages = lib.mkForce eacnixPkgs.linuxPackages-fedora;

      boot.kernelParams = [
        # Lockdown, integrity mode. Fedora already locks down under Secure
        # Boot; this also enforces it (and module signatures) without it.
        "lockdown=integrity"
        # IOMMU on, passthrough off. AMD's IOMMU is on by default in Fedora's
        # config, Intel's is not.
        "intel_iommu=on"
        "iommu.passthrough=0"
      ];
      # BPF LSM loaded and active: NixOS's security.lsm already appends `bpf`
      # and passes the list as `lsm=` (asserted below). Lockdown is an early
      # LSM, so `lsm=` doesn't need to name it.

      # kexec disabled.
      boot.kernel.sysctl."kernel.kexec_load_disabled" = 1;

      # libbpf resolves CONFIG_* externs from /boot/config-$(uname -r) or
      # /proc/config.gz. Fedora's kernel has no IKCONFIG and keeps its config
      # in Fedora's /boot, so BPF programs that read kconfig (every scx
      # scheduler) fail with "failed to open system Kconfig". These services
      # get a private /boot holding just that file; the real ESP is untouched.
      systemd.services = lib.genAttrs config.eacnix.kconfigServices (_: {
        serviceConfig = {
          TemporaryFileSystem = [ "/boot" ];
          BindReadOnlyPaths = [ "${kernel.configfile}:/boot/config-${kernel.modDirVersion}" ];
        };
      });

      # NixOS's default initrd list names modules Fedora doesn't build (e.g.
      # pcips2). The checks below keep this from hiding a module that matters.
      boot.initrd.allowMissingModules = true;

      warnings =
        let
          # NixOS's own default initrd list includes these and Fedora builds
          # neither; warning about them would fire on every system.
          absentDefaults = [
            "pcips2"
            "xhci_pci_prom21"
          ];
          missing = lib.subtractLists absentDefaults (
            missingModules config.boot.initrd.availableKernelModules
          );
        in
        lib.optional (
          missing != [ ]
        ) "eacnix: Fedora's kernel has no ${lib.concatStringsSep ", " missing}; the initrd will omit them.";

      assertions = [
        {
          assertion = missingModules config.boot.initrd.kernelModules == [ ];
          message = "eacnix: boot.initrd.kernelModules names modules Fedora's kernel lacks: ${lib.concatStringsSep ", " (missingModules config.boot.initrd.kernelModules)}";
        }
        {
          assertion = lib.elem "bpf" config.security.lsm;
          message = "eacnix: EAC requires the BPF LSM, but security.lsm doesn't include \"bpf\".";
        }
        {
          assertion = config.boot.extraModulePackages == [ ];
          message = ''
            eacnix: boot.extraModulePackages builds unsigned modules, which Fedora's kernel refuses under lockdown. Defined by:${extraModuleSources}
            Turn the option that adds them off in the eac specialisation only, e.g.
              specialisation.eac.configuration.hardware.xone.enable = lib.mkForce false;'';
        }
      ]
      # The kernel defines `features`, which makes NixOS skip these checks.
      ++ map (req: {
        assertion = req.assertion kernel.config;
        message = "eacnix: Fedora's kernel lacks a config NixOS requires: ${req.message}";
      }) config.system.requiredKernelConfig;
    };
in
{
  options.eacnix = {
    enable = lib.mkEnableOption "an EAC Linux v2 compliant boot target on Fedora's signed kernel";

    mode = lib.mkOption {
      type = lib.types.enum [
        "specialisation"
        "system"
      ];
      default = "specialisation";
      description = ''
        `specialisation`: add an `eac` specialisation to each generation and
        keep the normal system as it is.
        `system`: apply everything to the normal system, so it always runs
        Fedora's kernel: useful when the firmware trusts only Microsoft's keys
        (see "Your normal entry" in the README).
      '';
    };

    kconfigServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        lib.optional (config.services.scx.enable or false) "scx"
        ++ lib.optional ((config.services.scx_loader or { }).enable or false) "scx_loader";
      defaultText = lib.literalExpression ''
        lib.optional config.services.scx.enable "scx"
        ++ lib.optional config.services.scx_loader.enable "scx_loader"
      '';
      description = ''
        systemd services that load BPF programs reading kernel config (libbpf
        `__kconfig` externs), such as sched_ext schedulers. On the eac path
        each gets a private `/boot` with Fedora's kernel config at
        `/boot/config-<release>`, because Fedora's kernel has no
        `/proc/config.gz`. Applies to the eac system only.
      '';
    };

    boot = {
      install = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install the vendor boot path (Fedora's signed shim and grub, plus
          one BLS entry per recent eac generation) to the ESP whenever the
          bootloader is installed. Only systemd-boot is hooked; with another
          bootloader, run `eacnix-boot install` yourself.
        '';
      };

      directory = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_-]+";
        default = "eacnix";
        description = "Directory under `<ESP>/EFI` that eacnix owns.";
      };

      generations = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "How many recent eac generations get a boot entry, for rollback.";
      };

      timeout = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = "Seconds grub shows its menu on the eac path.";
      };

      hideFromSystemdBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Remove the eac specialisation from systemd-boot's menu. Booting it
          from there runs Fedora's kernel behind unsigned systemd-boot, which
          lands in the measured chain; only `eac-reboot` (firmware -> shim ->
          grub) is the compliant path.
        '';
      };

      label = lib.mkOption {
        type = lib.types.str;
        default = "NixOS EAC";
        description = ''
          Firmware boot entry for the vendor shim. It is created when
          `boot.loader.efi.canTouchEfiVariables` is set. `eac-reboot` boots it
          once through BootNext.
        '';
      };

      addToBootOrder = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Append the firmware entry to the end of BootOrder, so the firmware's
          boot menu lists it next to your other systems. eacnix only appends:
          it never reorders or removes entries, so your default stays first.
          It reapplies on every install, which brings the entry back after a
          firmware reset rebuilt BootOrder. Needs
          `boot.loader.efi.canTouchEfiVariables`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      eacnix-boot = eacnixPkgs.eacnix-boot;
      installCommand = lib.escapeShellArgs (
        [
          (lib.getExe eacnix-boot)
          "install"
          "--esp"
          config.boot.loader.efi.efiSysMountPoint
          "--chain"
          eacnixPkgs.fedora-boot-chain
          "--dir"
          cfg.boot.directory
          "--subpath"
          (if cfg.mode == "specialisation" then "specialisation/eac" else "")
          "--generations"
          (toString cfg.boot.generations)
          "--timeout"
          (toString cfg.boot.timeout)
          "--label"
          cfg.boot.label
        ]
        ++ lib.optional config.boot.loader.efi.canTouchEfiVariables "--register"
        ++ lib.optional cfg.boot.addToBootOrder "--add-to-boot-order"
        ++ lib.optionals (cfg.boot.hideFromSystemdBoot && config.boot.loader.systemd-boot.enable) [
          "--hide-systemd-boot-entries"
          "${
            if config.boot.loader.systemd-boot.xbootldrMountPoint != null then
              config.boot.loader.systemd-boot.xbootldrMountPoint
            else
              config.boot.loader.efi.efiSysMountPoint
          }/loader/entries"
        ]
      );
      # Preconfigured with this system's ESP directory and Fedora kernel release.
      eacnix-check = pkgs.writeShellScriptBin "eacnix-check" ''
        exec ${lib.getExe eacnixPkgs.eacnix-check} \
          --dir ${lib.escapeShellArg cfg.boot.directory} \
          --kernel-release ${eacnixPkgs.fedora-kernel.modDirVersion} "$@"
      '';
      eac-reboot = pkgs.writeShellScriptBin "eac-reboot" ''
        set -e
        ${lib.getExe eacnix-boot} next --label ${lib.escapeShellArg cfg.boot.label}
        exec systemctl reboot
      '';
    in
    lib.mkMerge [
      (lib.mkIf (cfg.mode == "specialisation") {
        specialisation.eac.configuration = eacConfig;
      })
      (lib.mkIf (cfg.mode == "system") (eacConfig {
        inherit config options lib;
      }))
      {
        environment.systemPackages = [
          eacnix-boot
          eacnix-check
          eac-reboot
        ];

        system.build.eacnix = {
          inherit (eacnixPkgs) fedora-kernel fedora-boot-chain;
          inherit eacnix-boot eacnix-check installCommand;
        };
      }
      (lib.mkIf cfg.boot.install {
        # systemd-boot has installed the normal entries by now. A failure here
        # (a full ESP, usually) leaves the eac path at its previous state, so it
        # warns instead of failing the whole switch over the secondary path.
        boot.loader.systemd-boot.extraInstallCommands = lib.mkAfter ''
          if ! ${installCommand}; then
            echo "warning: eacnix: the eac boot path was not updated (see above)." >&2
          fi
        '';

        assertions = [
          {
            assertion = cfg.boot.addToBootOrder -> config.boot.loader.efi.canTouchEfiVariables;
            message = "eacnix.boot.addToBootOrder needs boot.loader.efi.canTouchEfiVariables: without it the firmware entry is never created.";
          }
        ];

        warnings = lib.optional (!config.boot.loader.systemd-boot.enable) ''
          eacnix: the vendor boot path is only installed automatically alongside
          systemd-boot. Run this after each switch, or set eacnix.boot.install = false:
            ${installCommand}
        '';
      })
    ]
  );
}
