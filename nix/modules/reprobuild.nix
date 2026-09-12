# The reprobuild service modules — ONE definition, three module classes.
#
# This file is the SINGLE SOURCE OF TRUTH for the reprobuild option schema, the
# `caches.conf` renderer, and the daemon/reaper unit wiring. It used to live in
# `metacraft-labs/nixos-modules` (`modules/mcl-reprobuild`); it now lives here,
# next to the code it configures, and nixos-modules re-exports it. There is
# deliberately no second copy: a service definition maintained in two repos
# drifts, and the option schema is the contract the fleet deploys against.
#
# Distribution-And-Packaging M4 (§9): the flake exports these as
# `nixosModules.reprobuild` / `darwinModules.reprobuild` /
# `homeManagerModules.reprobuild`, so an EXTERNAL Nix user gets the services
# from reprobuild's own flake without depending on nixos-modules at all.
#
# The module installs the reprobuild `repro` build CLI onto a host AND renders
# the R1 binary-cache client trust config (`caches.conf`) from declarative
# options — so the whole fleet (servers + workstations + CI runners) can both
# BUILD with `repro` and SUBSTITUTE from the managed cache, the same way
# Nix+Attic substituters/trusted-public-keys are provisioned.
#
# This SUPERSEDED the former `mcl-repro-cache-client` module. That module
# installed a SEPARATE `repro-binary-cache-client` package which was just
# `reprobuild.overrideAttrs { pname = …; }` — the identical toolset renamed, so
# it duplicated the full closure and collided with this module on
# `lib/librepro_monitor_shim.so`. That standalone package was retired: the
# client toolset now ships as the `repro cache` subcommand group INSIDE the
# `reprobuild` package (Binary-Caches.md §"Client CLI Surface"), so there is one
# package here and the cache-client behaviour is purely the rendered
# `caches.conf` config.
#
# Three module classes are produced from ONE definition (shared option schema +
# renderer):
#   * nixos        — installs `repro` on the system PATH
#                    (`environment.systemPackages`) + system-wide
#                    `/etc/repro/caches.conf`, the SYSTEM-scope lease reaper,
#                    and the per-user daemon as a `systemd.user` unit.
#   * darwin       — the same system-wide install for nix-darwin hosts (macOS
#                    workstations), with the two lease daemons expressed as
#                    launchd jobs instead of systemd units.
#   * homeManager  — installs `repro` on the user PATH (`home.packages`) +
#                    per-user `~/.config/repro/caches.conf`, and the per-user
#                    daemon as a home-manager `systemd.user` service.
#
# The nixos and darwin classes are kept as separate bodies rather than one
# shared body with `optionalAttrs`: they agree on the package/etc/shell-hook
# surface (nix-darwin has all four of those options) but diverge completely on
# service management, and a merged body would have to name `systemd.*` options
# that do not exist on darwin.
#
# The R1 client (caches_config.nim) reads INI: system /etc/repro/caches.conf
# first, then ~/.config/repro/caches.conf (user OVERRIDES/EXTENDS by name).
# R1 is DEFAULT-UNTRUSTED: a cache is substituted from ONLY when its config
# entry lists a trusted-public-key. Rendering the fleet key here is what turns
# substitution ON — the load-bearing bit.
#
# `defaultPackageFor` is the one thing this file does NOT decide: the caller
# supplies `system: <the reprobuild package for that system>`. reprobuild's own
# flake passes `self.packages.${system}.reprobuild`; nixos-modules re-exports
# the already-applied modules, so a consuming flake (infra, ~/dotfiles) needs no
# `reprobuild` input of its own. Indexing an output attrset directly rather than
# going through flake-parts' `withSystem` is deliberate: `withSystem` reads
# `config.allSystems`, which — when a module is forced through
# `top.config.flake` inside a `perSystem` check — creates a
# perSystem->flake->perSystem eval cycle. Direct indexing has no such dependency.
{ defaultPackageFor }:
let
  # The canonical option path. `services.` (not `programs.`) because the payload
  # is two long-running daemons — the per-user lease registry/reaper and the
  # system-scope reaper — and because it is the path
  # Distribution-And-Packaging.milestones.org's M4 gate names.
  namespace = [
    "services"
    "reprobuild"
  ];

  # The historical option path, kept working by `legacyOptionNames` below.
  legacyNamespace = [
    "programs"
    "reprobuild"
  ];

  # Shared option schema + caches.conf renderer, parameterised only by the
  # concrete lib/pkgs of whichever module class instantiates it.
  mkShared =
    { lib, pkgs }:
    let
      inherit (lib)
        mkEnableOption
        mkOption
        types
        ;

      cacheType = types.submodule (
        { name, ... }:
        {
          options = {
            name = mkOption {
              type = types.str;
              default = name;
              description = ''
                Cache name — the `[section]` header in caches.conf and the key
                the user file overrides the system file by.
              '';
            };
            url = mkOption {
              type = types.str;
              example = "https://repro-cache.metacraft-labs.com";
              description = "HTTP(S) base URL of the reprobuild binary cache.";
            };
            trustedPublicKeys = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                130-hex-char (65-byte uncompressed ECDSA-P256) producer public
                keys trusted for this cache. R1 is default-untrusted: an entry
                with NO trusted key is never substituted from, so this list is
                what ENABLES substitution.
              '';
            };
            priority = mkOption {
              type = types.int;
              default = 30;
              description = "Substitution priority (lower wins, Nix convention).";
            };
          };
        }
      );

      # Render one `[cache]` section. Values are quoted, matching the R1
      # parser's canonical accepted syntax (std/parsecfg; see the R1 unit test
      # t_r1_caches_config.nim, whose fixtures use `url = "…"` /
      # `trusted-public-keys = "…"` / `priority = 20`). Trusted keys are joined
      # with `, ` (the parser splits on comma and/or whitespace).
      renderCache = c: ''
        [${c.name}]
        url = "${c.url}"
        trusted-public-keys = "${lib.concatStringsSep ", " c.trustedPublicKeys}"
        priority = ${toString c.priority}
      '';

      mkOptions = {
        enable = mkEnableOption "the reprobuild `repro` build CLI on PATH + rendered caches.conf";

        # Ephemeral-State-Leases L4 (§4.1): the daemon-hosted lease registry
        # + wall-clock reaper. Two scopes, two units:
        #   * a per-user `repro daemon serve` (systemd.user) owning the user
        #     lease scope (`~/.cache/repro/state`);
        #   * a system `repro daemon serve --system` owning the system lease
        #     scope (`/var/lib/repro/state`).
        # Both loop the L1 on-disk store, so leases + the reap schedule
        # survive a restart by construction.
        enableUserDaemon = mkEnableOption ''
          the per-user reprobuild daemon (`repro daemon serve`) as a
          `systemd.user` service. Beyond build/watch routing it hosts the
          USER-scope ephemeral-state lease registry + the wall-clock reaper
          (Ephemeral-State-Leases §4): it renews leases sent by `repro`
          reconciles and reaps idle leased state under `~/.cache/repro/state`.
          Requires `enable`
        '';

        enableSystemLeaseReaper = mkEnableOption ''
          the SYSTEM-scope reprobuild lease reaper (`repro daemon serve
          --system`) as a system service. It owns the system lease scope:
          the wall-clock reaper for fleet/CI-shared leased ephemeral state
          under `systemLeaseStateDir/state` (Ephemeral-State-Leases §4.1).
          Requires `enable`
        '';

        systemLeaseStateDir = mkOption {
          type = types.str;
          default = "/var/lib/repro";
          description = ''
            The system lease reaper's state root PARENT. The reaper serves the
            `state/` subdirectory under it (the `$REPRO_SYSTEM_STATE_DIR`
            convention `repro` uses to derive `systemLeaseStoreRoot`), so the
            on-disk store is `''${systemLeaseStateDir}/state`. Provisioned via
            `StateDirectory`, so it survives reaper restarts.
          '';
        };

        enableShellHook = mkEnableOption ''
          the direnv-like `repro shell hook` shell integration. Injects the
          on-`cd` reprobuild dev-env activation hook into interactive bash,
          zsh, and fish (the shells these modules manage; pwsh/nushell are
          out of scope here and handled by reprobuild's Windows home profile).
          The hook is a cheap upward walk for `reprobuild.nim` / `repro.nim` /
          `.repro/dev-env.lock` that no-ops in trees with no reprobuild
          dev-env, so it is safe to enable fleet-wide even where no `repro.nim`
          exists yet. Requires `enable`; the hook shells out to `repro` from
          this module's `package`
        '';

        package = mkOption {
          type = types.package;
          default = defaultPackageFor pkgs.stdenv.hostPlatform.system;
          defaultText = lib.literalMD "the reprobuild flake's `reprobuild` (native `repro`) package";
          description = "Package providing the `repro` build CLI (and the bundled cache-client tools).";
        };

        caches = mkOption {
          type = types.attrsOf cacheType;
          default = { };
          description = ''
            Binary caches to render into caches.conf. Each entry becomes one
            `[name]` section with `url`, `trusted-public-keys`, `priority`.
            Leave empty to install `repro` without provisioning any cache trust.
          '';
        };
      };

      # The rendered caches.conf text for a given `caches` attrset. Sections are
      # emitted in name order for a deterministic, diffable file.
      renderConfig =
        caches:
        let
          ordered = lib.sort (a: b: a.name < b.name) (lib.attrValues caches);
        in
        ''
          # Reprobuild binary-cache client trust config (caches.conf).
          # Rendered by the reprobuild flake's reprobuild module. Do not edit;
          # change the module options instead. R1 is default-untrusted: only a
          # cache listing a trusted-public-key here is substituted from.
        ''
        + lib.concatStringsSep "\n" (map renderCache ordered);
    in
    {
      inherit mkOptions renderConfig;
    };
in
{
  # ── System-wide (NixOS): repro on PATH + /etc/repro/caches.conf ───────────────
  nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.reprobuild;
      shared = mkShared { inherit lib pkgs; };
    in
    {
      options.services.reprobuild = shared.mkOptions;

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];
        # System file the R1 client reads FIRST (the user file extends it). Only
        # written when caches are declared, so `enable` alone just installs repro.
        environment.etc."repro/caches.conf" = lib.mkIf (cfg.caches != { }) {
          text = shared.renderConfig cfg.caches;
        };
        # Direnv-like on-`cd` dev-env activation, injected system-wide into the
        # shells NixOS manages. bash/zsh source via `eval`, fish via `| source`
        # (the sourcing idioms `repro shell hook <shell>` documents). A no-op
        # walk where there is no reprobuild dev-env.
        programs.bash.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook bash)"
        '';
        programs.zsh.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook zsh)"
        '';
        programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          ${cfg.package}/bin/repro shell hook fish | source
        '';

        # Ephemeral-State-Leases L4 (§4.1) — the SYSTEM-scope lease reaper.
        # `repro daemon serve --system` binds the system lease scope + reaps
        # idle leased ephemeral state under `''${systemLeaseStateDir}/state`
        # on its wall-clock tick. Type=simple long-running unit;
        # `StateDirectory` provisions the durable store so leases + the reap
        # schedule survive a restart (the store is the source of truth, not
        # daemon memory). `--state-root` points it explicitly at the
        # StateDirectory subdir, and the endpoint/state-dir live under
        # `/run`+`/var/lib` so it never collides with a per-user daemon.
        systemd.services.repro-lease-reaper = lib.mkIf cfg.enableSystemLeaseReaper {
          description = "Reprobuild system-scope ephemeral-state lease reaper";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = lib.concatStringsSep " " [
              "${cfg.package}/bin/repro"
              "daemon"
              "serve"
              "--foreground"
              "--system"
              "--endpoint"
              "/run/repro/repro-system-daemon.sock"
              "--state-dir"
              "/var/lib/repro/daemon"
              "--state-root"
              "${cfg.systemLeaseStateDir}/state"
            ];
            Restart = "on-failure";
            RestartSec = 5;
            RuntimeDirectory = "repro";
            # `state` is the lease store; `daemon` is the daemon's own
            # runtime state-dir (logs/status/lock). Both under /var/lib/repro.
            StateDirectory = "repro repro/state repro/daemon";
            DynamicUser = false;
          };
        };

        # The per-user daemon, NixOS-side. The home-manager class below renders
        # the same unit for home-manager users; this arm is what makes
        # `services.reprobuild.enableUserDaemon` mean something on a plain NixOS
        # host that has no home-manager — which is exactly the external consumer
        # Distribution-And-Packaging M4's gate describes. `systemd.user.services`
        # is a NixOS option in its own right (it populates the user manager's
        # unit directory), so the two arms are alternative delivery mechanisms
        # for ONE unit, not a second definition of it: they agree on name,
        # ExecStart, Restart, RestartSec and WantedBy. A host running both
        # home-manager and this class gets the home-manager copy, which wins
        # because it is written into the user's own profile.
        systemd.user.services.repro-daemon = lib.mkIf cfg.enableUserDaemon {
          description = "Reprobuild per-user daemon (lease registry + reaper)";
          after = [ "default.target" ];
          wantedBy = [ "default.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${cfg.package}/bin/repro daemon serve --foreground";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };

  # ── System-wide (nix-darwin): repro on PATH + /etc/repro/caches.conf ─────────
  darwin =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.reprobuild;
      shared = mkShared { inherit lib pkgs; };
      systemStateRoot = "${cfg.systemLeaseStateDir}/state";
      systemDaemonStateDir = "${cfg.systemLeaseStateDir}/daemon";
      systemEndpoint = "/var/run/repro/repro-system-daemon.sock";
    in
    {
      options.services.reprobuild = shared.mkOptions;

      config = lib.mkIf cfg.enable {
        # Identical surface to the NixOS class: nix-darwin provides
        # `environment.systemPackages`, `environment.etc` (materialised through
        # /etc/static), and `programs.{bash,zsh,fish}.interactiveShellInit`, so
        # the R1 client finds /etc/repro/caches.conf at the same path it reads
        # on Linux and the dev-env hook lands in the same shells.
        environment.systemPackages = [ cfg.package ];
        environment.etc."repro/caches.conf" = lib.mkIf (cfg.caches != { }) {
          text = shared.renderConfig cfg.caches;
        };
        programs.bash.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook bash)"
        '';
        programs.zsh.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook zsh)"
        '';
        programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          ${cfg.package}/bin/repro shell hook fish | source
        '';

        # Ephemeral-State-Leases L4 (§4.1), darwin edition — the SYSTEM-scope
        # lease reaper as a launchd daemon rather than a systemd unit. launchd
        # has no `StateDirectory` equivalent, so the store directories are
        # created by the job's own script before exec (the same shape the
        # netbird darwin daemon uses). `KeepAlive` + `ThrottleInterval` stand in
        # for `Restart=on-failure` / `RestartSec`.
        launchd.daemons.repro-lease-reaper = lib.mkIf cfg.enableSystemLeaseReaper {
          script = ''
            mkdir -p ${lib.escapeShellArg systemStateRoot} \
                      ${lib.escapeShellArg systemDaemonStateDir} \
                      /var/run/repro
            exec ${cfg.package}/bin/repro daemon serve \
              --foreground \
              --system \
              --endpoint ${lib.escapeShellArg systemEndpoint} \
              --state-dir ${lib.escapeShellArg systemDaemonStateDir} \
              --state-root ${lib.escapeShellArg systemStateRoot}
          '';
          serviceConfig = {
            Label = "org.metacraft.repro-lease-reaper";
            RunAtLoad = true;
            KeepAlive = true;
            ThrottleInterval = 5;
            StandardOutPath = "/var/log/repro-lease-reaper.out.log";
            StandardErrorPath = "/var/log/repro-lease-reaper.err.log";
          };
        };

        # The per-user daemon as a launchd LaunchAgent (nix-darwin's
        # `launchd.user.agents`, the `systemd.user` analogue). Like the
        # home-manager class it pins no endpoint: the daemon self-discovers its
        # per-user socket + state-dir from `$XDG_*`.
        launchd.user.agents.repro-daemon = lib.mkIf cfg.enableUserDaemon {
          command = "${cfg.package}/bin/repro daemon serve --foreground";
          serviceConfig = {
            Label = "org.metacraft.repro-daemon";
            RunAtLoad = true;
            KeepAlive = true;
            ThrottleInterval = 5;
          };
        };
      };
    };

  # ── Per-user (home-manager): repro on PATH + ~/.config/repro/caches.conf ──────
  homeManager =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.reprobuild;
      shared = mkShared { inherit lib pkgs; };
    in
    {
      options.services.reprobuild = shared.mkOptions;

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
        # XDG user file the R1 client reads AFTER the system file, overriding /
        # extending it by cache name (~/.config/repro/caches.conf).
        xdg.configFile."repro/caches.conf" = lib.mkIf (cfg.caches != { }) {
          text = shared.renderConfig cfg.caches;
        };
        # Direnv-like on-`cd` dev-env activation, injected per-user into the
        # shells home-manager manages. Uses each shell module's current init
        # option (bash `initExtra`, zsh `initContent`, fish
        # `interactiveShellInit`). A no-op walk where there is no reprobuild
        # dev-env, so it coexists with an already-active direnv hook.
        programs.bash.initExtra = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook bash)"
        '';
        programs.zsh.initContent = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook zsh)"
        '';
        programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          ${cfg.package}/bin/repro shell hook fish | source
        '';

        # Ephemeral-State-Leases L4 (§4.1) — the per-user daemon as a
        # `systemd.user` service. `repro daemon serve` hosts the USER-scope
        # lease registry + wall-clock reaper (renews leases sent by `repro`
        # reconciles, reaps idle leased state under `~/.cache/repro/state`).
        # Type=simple long-running; Restart keeps it resident so wall-clock
        # reaping is prompt. The store is on disk, so leases survive a restart
        # of this unit. The daemon self-discovers its per-user socket +
        # state-dir from `$XDG_*`, so no explicit endpoint is pinned here.
        systemd.user.services.repro-daemon = lib.mkIf cfg.enableUserDaemon {
          Unit = {
            Description = "Reprobuild per-user daemon (lease registry + reaper)";
            After = [ "default.target" ];
          };
          Install.WantedBy = [ "default.target" ];
          Service = {
            Type = "simple";
            ExecStart = "${cfg.package}/bin/repro daemon serve --foreground";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };

  # ── Compatibility: the historical `programs.reprobuild` option path ──────────
  #
  # The schema above moved from `programs.reprobuild` to `services.reprobuild`
  # when it moved out of nixos-modules. Every deployment that already says
  # `programs.reprobuild.* = …` (the infra fleet's `default-server-config`,
  # ~/dotfiles, nixos-modules' own checks) keeps working through this module.
  #
  # The alias list is DERIVED from `mkOptions`' attribute names, not written
  # out — a new option added above is aliased automatically and a removed one
  # disappears from both paths at once, so the two paths cannot drift. Aliasing
  # is per-leaf on purpose: `lib.mkAliasOptionModule` copies the TYPE of the
  # TARGET option, and pointing it at an option *tree* instead of a leaf would
  # silently degrade the type to `types.submodule { }` and accept nonsense.
  #
  # Exported separately from the three classes above so the canonical export
  # stays clean: an external consumer imports `nixosModules.reprobuild` and
  # never sees the legacy path.
  legacyOptionNames =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = map (
        name: lib.mkAliasOptionModule (legacyNamespace ++ [ name ]) (namespace ++ [ name ])
      ) (builtins.attrNames (mkShared { inherit lib pkgs; }).mkOptions);
    };
}
