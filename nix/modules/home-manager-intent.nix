# `reprobuild.homeManagerModules.intent` -- a Home Manager module that applies
# a Reprobuild profile's evaluated intent, one category at a time.
#
# The profile (home.nim and its data files) stays the source of truth; this
# module reads its `repro home export` through `reprobuild.lib.readIntent`
# (a committed snapshot, or IFD) for this host and system, and translates the
# categories the host opts into (reprobuild-pm spec
# Gradual-Nix-To-Reprobuild-Migration.md §The Nix helper library, §The
# adoption ladder rung 2: Reprobuild owns the fact, Nix applies it):
#
#   reprobuild.intent.packages.enable     -> home.packages
#   reprobuild.intent.homebrew.enable     -> reprobuild.intent.homebrew.{casks,formulae}
#                                            (read by the host's Homebrew module;
#                                            Home Manager has no Homebrew option):
#                                            pkg.homebrewCask / pkg.homebrewFormula
#                                            resources, and the packages
#                                            `homebrew.realizationOf` claims
#                                            (default: reprobuild.lib.brewRealizationOf)
#   reprobuild.intent.files.enable        -> home.file
#   reprobuild.intent.environment.enable  -> home.sessionVariables / home.sessionPath
#
# Mapping rules: nix/lib/home-manager-mapping.nix. Entries that cannot be
# mapped are reported in `reprobuild.intent.unmapped` / `.uncategorized`, and
# FAIL the evaluation by default (an assertion naming each entry) --
# never dropped, and never merely warned about unless the configuration opts
# into that explicitly (`unmappedPolicy` / `uncategorizedPolicy = "warn"`;
# Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped). Entries
# of a category the host did not enable are excluded: that is the host's
# explicit opt-out, not input the module failed to recognise.
#
# User documentation: docs/user-guide/nix-helper-library.md.
{ reprobuildLib }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.reprobuild.intent;
  mapping = import ../lib/home-manager-mapping.nix { inherit lib; };

  result = reprobuildLib.readIntent (
    {
      inherit (cfg) host system;
    }
    // lib.optionalAttrs (cfg.snapshot != null) { inherit (cfg) snapshot; }
    // lib.optionalAttrs (cfg.profileDir != null) { inherit (cfg) profileDir; }
    // lib.optionalAttrs (cfg.buildSystem != null) { inherit (cfg) buildSystem; }
  );

  mapped = mapping.mapIntent {
    inherit (result) evaluation;
    inherit pkgs;
    inherit (cfg) system;
    categories = {
      packages = cfg.packages.enable;
      homebrew = cfg.homebrew.enable;
      files = cfg.files.enable;
      environment = cfg.environment.enable;
    };
    inherit (reprobuildLib) lookupNixRealization;
    brewRealizationOf = cfg.homebrew.realizationOf;
  };

  describe = e: "${e.category}: ${e.id}: ${e.reason}";
  policyMessages =
    policy: what: entries:
    lib.optional (entries != [ ]) {
      inherit policy;
      message = "reprobuild.intent: ${toString (builtins.length entries)} ${what} for host ${cfg.host} on ${cfg.system}:\n  ${
        lib.concatMapStringsSep "\n  " describe entries
      }";
    };
  reports =
    policyMessages cfg.unmappedPolicy
      "intent entries of enabled categories could not be mapped onto Home Manager"
      mapped.unmapped
    ++
      policyMessages cfg.uncategorizedPolicy
        "intent entries have no Home Manager category (Reprobuild applies them, or nothing does)"
        mapped.uncategorized;

  category =
    name: description:
    lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption description;
      };
      default = { };
    };
in
{
  options.reprobuild.intent = {
    enable = lib.mkEnableOption "applying a Reprobuild profile's evaluated intent through Home Manager";

    host = lib.mkOption {
      type = lib.types.str;
      description = "The host the profile is evaluated for (its `hosts:` entry selects the activities).";
    };
    system = lib.mkOption {
      type = lib.types.str;
      default = pkgs.stdenv.hostPlatform.system;
      defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.system";
      description = "The target system the guards are evaluated for (a `repro home export --target` name).";
    };
    snapshot = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "A committed `repro home export` document (snapshot mode). Kept current with `repro home export --check`.";
    };
    profileDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "The profile directory, for IFD mode (used when `snapshot` is null).";
    };
    buildSystem = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IFD mode: the system that runs `repro home export` -- the evaluator's, not the target's. Defaults to builtins.currentSystem where the evaluation exposes it.";
    };

    packages = category "packages" "home.packages from the intent's packages (nixpkgs attributes from the reprobuild-nix-packages catalog)";
    files = category "files" "home.file from fs.userFile resources";
    environment = category "environment" "home.sessionVariables / home.sessionPath from env.userVariable / env.userPath resources";
    homebrew = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Homebrew token lists from pkg.homebrewCask / pkg.homebrewFormula resources and Homebrew-realized packages";
          realizationOf = lib.mkOption {
            type = lib.types.functionTo (lib.types.nullOr (lib.types.attrsOf lib.types.str));
            # The pinned Homebrew contribution catalog (reprobuild-brew-packages),
            # read by `reprobuild.lib.brewRealizationOf`.
            default = reprobuildLib.brewRealizationOf;
            defaultText = lib.literalExpression "reprobuild.lib.brewRealizationOf";
            description = "Hook: `{ name, system }` -> null or `{ kind = \"cask\" | \"formula\"; token; tap; }`, the Homebrew realization of a canonical package. Defaults to `reprobuild.lib.brewRealizationOf`, which reads the Homebrew contribution catalog the reprobuild flake pins (reprobuild-brew-packages): a cask claims a package on darwin systems, a formula on darwin and Linux. A package it claims goes to the token lists instead of home.packages; set `_: null` to claim nothing.";
          };
          casks = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            readOnly = true;
            description = "Cask tokens the intent asks for (output).";
          };
          formulae = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            readOnly = true;
            description = "Formula tokens the intent asks for (output).";
          };
        };
      };
      default = { };
    };

    unmappedPolicy = lib.mkOption {
      type = lib.types.enum [
        "error"
        "warn"
      ];
      default = "error";
      description = "What an entry of an enabled category that cannot be mapped does: fail the evaluation (an assertion, the default) or, as an explicit opt-in, warn.";
    };
    uncategorizedPolicy = lib.mkOption {
      type = lib.types.enum [
        "error"
        "warn"
      ];
      default = "error";
      description = "What an entry no category covers (config overrides, resource kinds Home Manager has no option for) does: fail the evaluation (an assertion, the default) or, as an explicit opt-in while Reprobuild applies those entries, warn.";
    };

    evaluation = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      description = "The evaluated intent (output): what `repro home export --target` reports for this host and system.";
    };
    unmapped = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      description = "Entries of enabled categories that could not be mapped (output): `{ category, id, reason }`.";
    };
    uncategorized = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      description = "Entries no category covers (output): `{ category, id, reason }`.";
    };
  };

  config = lib.mkIf cfg.enable {
    reprobuild.intent = {
      inherit (result) evaluation;
      inherit (mapped) unmapped uncategorized;
      homebrew = {
        inherit (mapped) casks formulae;
      };
    };

    home.packages = lib.mkIf cfg.packages.enable mapped.packages;
    home.file = lib.mkIf cfg.files.enable mapped.files;
    home.sessionVariables = lib.mkIf cfg.environment.enable mapped.sessionVariables;
    home.sessionPath = lib.mkIf cfg.environment.enable mapped.sessionPath;

    assertions = map (r: {
      assertion = false;
      inherit (r) message;
    }) (lib.filter (r: r.policy == "error") reports);
    warnings = map (r: r.message) (lib.filter (r: r.policy == "warn") reports);
  };
}
