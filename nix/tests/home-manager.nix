# The flake check `lib-home-manager`: `reprobuild.homeManagerModules.intent`
# in a real Home Manager evaluation, over the committed neutral export
# (tests/fixtures/intent-exports/neutral/export.json) for host `home-pc` on
# this check's system.
#
# Decided at evaluation time, like `lib-tests`, so every system's check is
# meaningful from any evaluator. The expectations are written out per
# platform below rather than recomputed with the mapping code: the fixture's
# evaluation for home-pc is in evaluations.json, and what each entry must map
# to is the point of the test. Home Manager is the revision devops-modules
# pins (`home-manager-unstable`, following the same nixpkgs as this flake),
# reached through the existing `nixos-modules` input -- no new lock node.
{
  lib,
  pkgs,
  system,
  homeManager,
  intentModule,
  brewIntentModule,
  root,
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
  snapshot = root + "/tests/fixtures/intent-exports/neutral/export.json";

  configWith =
    module: extra:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home = {
            username = "gm5";
            homeDirectory = if isDarwin then "/Users/gm5" else "/home/gm5";
            stateVersion = "25.05";
          };
          reprobuild.intent = {
            enable = true;
            host = "home-pc";
            inherit snapshot;
            packages.enable = true;
            files.enable = true;
            environment.enable = true;
            homebrew.enable = true;
            unmappedPolicy = "warn";
            uncategorizedPolicy = "warn";
          };
        }
        extra
      ];
    }).config;
  configFor = configWith intentModule;

  all = configFor { };
  outPaths = ps: map (p: p.outPath) ps;
  ids = entries: lib.sort (a: b: a < b) (map (e: e.id) entries);
  ourFiles = cfg: lib.filterAttrs (n: _: lib.elem n (lib.attrNames expected.files)) cfg.home.file;

  expected = {
    packages = [
      pkgs.bash
      pkgs.llvm.dev
    ]
    ++ lib.optionals isLinux [
      pkgs.busybox
      pkgs.patchelf
    ];
    unmapped = lib.sort (a: b: a < b) (
      [
        "fs.userFile:~/.ssh/gm5-secret" # mode 0600
        "package:cmake" # pinned to a version pkgs.cmake is not
        "package:gm5-home-pc-only" # no Nix realization in the catalog
        "package:ripgrep" # no Nix realization in the catalog
      ]
      ++ lib.optional isDarwin "package:busybox" # Linux-only in nixpkgs
      ++ lib.optional (system == "aarch64-darwin") "package:gm5-mac-arm-tool"
    );
    uncategorized = [
      "config:git.credentialHelper"
      "fs.managedBlock:~/.bashrc:gm5"
    ];
    files = {
      ".local/bin/gm5-hello" = {
        text = "#!/bin/sh\necho hello\n";
        executable = true;
      };
    }
    // (
      if isDarwin then
        {
          "Library/Preferences/gm5.conf" = {
            text = "mac = 1\n";
            executable = false;
          };
        }
      else
        {
          ".config/gm5/linux.conf" = {
            text = "linux = 1\n";
            executable = false;
          };
        }
    );
    casks = lib.optional isDarwin "gm5-cask";
  };

  # Every intent package mapped is in home.packages; nothing unmapped is.
  packagesOk =
    let
      have = outPaths all.home.packages;
    in
    lib.all (p: lib.elem p have) (outPaths expected.packages) && !(lib.elem pkgs.cmake.outPath have);

  filesOk = lib.mapAttrs (_: f: { inherit (f) text executable; }) (ourFiles all) == expected.files;

  # Disabled categories contribute nothing and report nothing (the host left
  # them to Reprobuild); uncategorized entries are still reported.
  none = configFor {
    reprobuild.intent = {
      packages.enable = lib.mkForce false;
      files.enable = lib.mkForce false;
      environment.enable = lib.mkForce false;
      homebrew.enable = lib.mkForce false;
    };
  };
  disabledOk =
    !(lib.any (p: lib.elem p (outPaths none.home.packages)) (outPaths expected.packages))
    && ourFiles none == { }
    && !(none.home.sessionVariables ? GM5_EDITOR)
    && none.reprobuild.intent.unmapped == [ ]
    && none.reprobuild.intent.homebrew.casks == [ ]
    && ids none.reprobuild.intent.uncategorized == expected.uncategorized;

  # The DEFAULT policies fail the evaluation, for unmapped and uncategorized
  # entries alike (Core-Invariants.md §Unrecognised Input Is Rejected, Not
  # Skipped): Home Manager throws "Failed assertions" on any access to the
  # configuration, and each failed assertion's message names the entries.
  # Warning is an explicit opt-in per policy. `configForDefaults` sets no
  # policy at all, so a default that drifts to "warn" turns this red.
  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;
  # Home Manager's configuration throws on a failed assertion as a whole
  # (`moduleChecks` wraps every attribute it returns), so the assertion
  # MESSAGES cannot be read from a real Home Manager evaluation -- only the
  # failure, which `fails` below asserts on the real one. To check that the
  # messages name the entries, the same module is also evaluated with
  # `lib.evalModules` against a minimal declaration of the six Home Manager
  # options it writes (justified stand-in: it reads nothing back from them,
  # and stands in only for reading `assertions` unchecked).
  hmOptionsStub = {
    options = {
      home.packages = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
      };
      home.file = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
      };
      home.sessionVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
      };
      home.sessionPath = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };
  failedMessages =
    extra:
    let
      cfg =
        (lib.evalModules {
          modules = [
            intentModule
            hmOptionsStub
            {
              _module.args.pkgs = pkgs;
              reprobuild.intent = {
                enable = true;
                host = "home-pc";
                inherit snapshot;
              };
            }
            extra
          ];
        }).config;
    in
    map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  configForDefaults =
    extra:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        intentModule
        {
          home = {
            username = "gm5";
            homeDirectory = if isDarwin then "/Users/gm5" else "/home/gm5";
            stateVersion = "25.05";
          };
          reprobuild.intent = {
            enable = true;
            host = "home-pc";
            inherit snapshot;
          };
        }
        extra
      ];
    }).config;
  # Only uncategorized entries (no category enabled): the default fails.
  onlyUncategorized = { };
  # Unmapped entries too (packages enabled), uncategorized opted into warn.
  unmappedWithUncategorizedWarned = {
    reprobuild.intent = {
      packages.enable = true;
      uncategorizedPolicy = "warn";
    };
  };
  bothWarned = {
    reprobuild.intent = {
      packages.enable = true;
      unmappedPolicy = "warn";
      uncategorizedPolicy = "warn";
    };
  };
  policyOk =
    fails (outPaths (configForDefaults onlyUncategorized).home.packages)
    && lib.any (m: lib.hasInfix "fs.managedBlock:~/.bashrc:gm5" m && lib.hasInfix "config:git.credentialHelper" m) (
      failedMessages onlyUncategorized
    )
    && fails (outPaths (configForDefaults unmappedWithUncategorizedWarned).home.packages)
    && lib.any (m: lib.hasInfix "package:ripgrep" m) (failedMessages unmappedWithUncategorizedWarned)
    && !(lib.any (m: lib.hasInfix "fs.managedBlock" m) (failedMessages unmappedWithUncategorizedWarned))
    # The explicit opt-in: both policies "warn" -> the evaluation succeeds
    # and the entries are warned about by name.
    && !(fails (outPaths (configForDefaults bothWarned).home.packages))
    && failedMessages bothWarned == [ ]
    && lib.any (w: lib.hasInfix "package:ripgrep" w) all.warnings
    && lib.any (w: lib.hasInfix "fs.managedBlock:~/.bashrc:gm5" w) all.warnings;

  # Input the mapping does not recognise is reported, never skipped: a
  # resource kind it does not know (whichever categories are on -- it cannot
  # tell which category the kind would belong to), and a field of a mapped
  # kind it does not know (the file is not placed without it).
  neutralDoc = builtins.fromJSON (builtins.readFile snapshot);
  strField = value: {
    kind = "string";
    inherit value;
  };
  unrecognisedSnapshot = builtins.toFile "gm5-unrecognised.json" (
    builtins.toJSON (
      neutralDoc
      // {
        intent = neutralDoc.intent // {
          resources = neutralDoc.intent.resources ++ [
            {
              kind = "fs.userSymlink";
              address = "fs.userSymlink:~/gm5-link";
              fields.hostFile = strField "~/gm5-link";
              guard = null;
              dependsOn = [ ];
            }
            {
              kind = "fs.userFile";
              address = "fs.userFile:~/gm5-owned";
              fields = {
                hostFile = strField "~/gm5-owned";
                content = strField "x\n";
                mode = strField "0644";
                executable = {
                  kind = "bool";
                  value = false;
                };
                owner = strField "root";
              };
              guard = null;
              dependsOn = [ ];
            }
          ];
        };
      }
    )
  );
  unrecognised = configFor {
    reprobuild.intent = {
      snapshot = lib.mkForce unrecognisedSnapshot;
      packages.enable = lib.mkForce false;
      environment.enable = lib.mkForce false;
      homebrew.enable = lib.mkForce false;
    };
  };
  unrecognisedNoCategories = configFor {
    reprobuild.intent = {
      snapshot = lib.mkForce unrecognisedSnapshot;
      packages.enable = lib.mkForce false;
      files.enable = lib.mkForce false;
      environment.enable = lib.mkForce false;
      homebrew.enable = lib.mkForce false;
    };
  };
  unrecognisedOk =
    ids unrecognised.reprobuild.intent.unmapped == [
      "fs.userFile:~/.ssh/gm5-secret"
      "fs.userFile:~/gm5-owned"
      "fs.userSymlink:~/gm5-link"
    ]
    && !(unrecognised.home.file ? "gm5-owned")
    && ids unrecognisedNoCategories.reprobuild.intent.unmapped == [ "fs.userSymlink:~/gm5-link" ]
    && fails (
      (configFor {
        reprobuild.intent = {
          snapshot = lib.mkForce unrecognisedSnapshot;
          unmappedPolicy = lib.mkForce "error";
          packages.enable = lib.mkForce false;
          files.enable = lib.mkForce false;
          environment.enable = lib.mkForce false;
          homebrew.enable = lib.mkForce false;
        };
      }).home.packages
    );

  # GM5b: the module's DEFAULT `homebrew.realizationOf` hook is
  # `reprobuild.lib.brewRealizationOf` over the flake's catalogs. Here the
  # module is built over the Nix catalog plus tests/fixtures/brew-catalog,
  # which claims `ripgrep` as cask `gm5b-ripgrep` and `gm5-home-pc-only` as
  # formula `gm5b-only`: on darwin both leave `unmapped` for the token lists;
  # on Linux the cask does not apply (casks are macOS-only), so `ripgrep`
  # stays unmapped while the formula is claimed.
  brew = configWith brewIntentModule { };
  sortStrings = lib.sort (a: b: a < b);
  brewExpected = {
    casks = sortStrings (expected.casks ++ lib.optional isDarwin "gm5b-ripgrep");
    formulae = lib.optional (isDarwin || isLinux) "gm5b-only";
    unmapped = lib.filter (
      id: id != "package:gm5-home-pc-only" && !(isDarwin && id == "package:ripgrep")
    ) expected.unmapped;
  };
  brewOk =
    sortStrings brew.reprobuild.intent.homebrew.casks == brewExpected.casks
    && brew.reprobuild.intent.homebrew.formulae == brewExpected.formulae
    && ids brew.reprobuild.intent.unmapped == brewExpected.unmapped
    # Homebrew disabled: the hook claims nothing and the packages are the
    # `packages` category's again (unmapped, as without the catalog).
    && ids (configWith brewIntentModule { reprobuild.intent.homebrew.enable = lib.mkForce false; })
      .reprobuild.intent.unmapped == expected.unmapped
    # An explicit `_: null` hook claims nothing even with the catalog.
    && ids (configWith brewIntentModule { reprobuild.intent.homebrew.realizationOf = lib.mkForce (_: null); })
      .reprobuild.intent.unmapped == expected.unmapped
    # The flake's own module reads the pinned catalogs; nothing in the
    # neutral fixture is a catalog application, so it claims nothing there.
    && all.reprobuild.intent.homebrew.formulae == [ ];

  # GM7 (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply): over
  # tests/fixtures/intent-exports/concerns/export.json. `m1` declares
  # `applies: [applications, environment]` (Reprobuild the applications, Nix
  # the packages), `server` declares `applies: [packages]` (the reverse) and
  # `home-pc` declares nothing. Every category switch DEFAULTS to the
  # complement of the declaration; home-pc keeps today's opt-in defaults (all
  # off). Uncategorized entries of a concern Reprobuild applies are excluded.
  # Packages are routed by the concern Reprobuild's export classified them
  # into for this system (`concerns.packages`, carried as
  # `evaluation.packages[].concern`): the fixture catalog's `gm7app` is a
  # disk-image application on the darwin targets, so on m1 it is
  # Reprobuild's (excluded) and on server it is Nix's (the Homebrew category,
  # which claims nothing for it, reports it). An explicit switch overrides
  # the default, and one whose concern Reprobuild also applies is warned
  # about.
  concernsSnapshot = root + "/tests/fixtures/intent-exports/concerns/export.json";
  concernsConfig =
    host: extra:
    (homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        intentModule
        {
          home = {
            username = "gm7";
            homeDirectory = if isDarwin then "/Users/gm7" else "/home/gm7";
            stateVersion = "25.05";
          };
          reprobuild.intent = {
            enable = true;
            inherit host;
            snapshot = concernsSnapshot;
            unmappedPolicy = "warn";
            uncategorizedPolicy = "warn";
          };
        }
        extra
      ];
    }).config;
  concernsM1 = concernsConfig "m1" { };
  concernsServer = concernsConfig "server" { };
  concernsHomePc = concernsConfig "home-pc" { };
  m1Applies = [
    "applications"
    "environment"
  ];
  categoryConcerns = {
    packages = "packages";
    homebrew = "applications";
    files = "files";
    environment = "environment";
  };
  switchesOf = cfg: lib.mapAttrs (name: _: cfg.reprobuild.intent.${name}.enable) categoryConcerns;
  complementOf = applies: lib.mapAttrs (_: concern: !(lib.elem concern applies)) categoryConcerns;
  evalPackage = cfg: name: lib.findFirst (p: p.name == name) null cfg.reprobuild.intent.evaluation.packages;
  unmappedIn =
    cfg: category: id:
    lib.any (e: e.id == id && e.category == category) cfg.reprobuild.intent.unmapped;
  concernsOk =
    concernsM1.reprobuild.intent.evaluation.applies == m1Applies
    && concernsServer.reprobuild.intent.evaluation.applies == [ "packages" ]
    && !(concernsHomePc.reprobuild.intent.evaluation ? applies)
    # The defaults ARE the complement of the declaration, category by
    # category, and nothing on an undeclared host.
    && switchesOf concernsM1 == complementOf m1Applies
    && switchesOf concernsServer == complementOf [ "packages" ]
    && switchesOf concernsHomePc == lib.mapAttrs (_: _: false) categoryConcerns
    # What the defaults do: files placed, the variable left to Reprobuild.
    && concernsM1.home.file ? ".config/gm7/app.conf"
    && !(concernsM1.home.sessionVariables ? GM7_EDITOR)
    && lib.elem pkgs.bash.outPath (outPaths concernsM1.home.packages)
    && !(concernsHomePc.home.file ? ".config/gm7/app.conf")
    && !(lib.elem pkgs.bash.outPath (outPaths concernsHomePc.home.packages))
    # Uncategorized: Reprobuild's (environment) excluded, Nix's reported.
    && ids concernsM1.reprobuild.intent.uncategorized == [ "config:git.credentialHelper" ]
    && ids concernsHomePc.reprobuild.intent.uncategorized == [
      "config:git.credentialHelper"
      "fs.managedBlock:~/.bashrc:gm7"
    ]
    && !(lib.any (w: lib.hasInfix "both sides apply" w) concernsM1.warnings);
  # The per-package split (Open question 9): routed by Reprobuild's
  # classification for this system, never by a list on the Nix side.
  concernsPackagesOk =
    let
      bashOnM1 = evalPackage concernsM1 "bash";
      app = evalPackage concernsM1 "gm7app";
      appOnServer = evalPackage concernsServer "gm7app";
      notOnNix = cfg: !(lib.any (e: e.id == "package:gm7app") cfg.reprobuild.intent.unmapped);
    in
    # Only a declaring host's packages carry a concern.
    !(lib.any (p: p ? concern) concernsHomePc.reprobuild.intent.evaluation.packages)
    && bashOnM1.concern == "packages"
    && bashOnM1.resolved == true
    && (
      if isDarwin then
        # Vacuity: the application IS in the darwin evaluation, classified
        # by the export.
        app.concern == "applications"
        && app.resolved
        && appOnServer.concern == "applications"
        # m1: Reprobuild's -- neither nixpkgs nor Homebrew sees it.
        && notOnNix concernsM1
        && !(lib.elem "gm7app" concernsM1.reprobuild.intent.homebrew.casks)
        # server: Nix's application, and the Homebrew category reports that
        # it claims nothing for it.
        && unmappedIn concernsServer "homebrew" "package:gm7app"
      else
        app == null && appOnServer == null && notOnNix concernsM1 && notOnNix concernsServer
    )
    # server: the packages are Reprobuild's; nothing of them reaches Nix.
    && !(lib.elem pkgs.bash.outPath (outPaths concernsServer.home.packages))
    && concernsServer.reprobuild.intent.homebrew.formulae == [ ]
    && !(lib.any (e: lib.hasPrefix "package:" e.id && e.id != "package:gm7app") concernsServer.reprobuild.intent.unmapped);
  # Overridable, and an override against the declaration is warned about.
  concernsOverrideOk =
    let
      both = concernsConfig "m1" { reprobuild.intent.environment.enable = true; };
      off = concernsConfig "m1" { reprobuild.intent.files.enable = false; };
    in
    both.home.sessionVariables.GM7_EDITOR or null == "nvim"
    && lib.any (w: lib.hasInfix "category `environment` is enabled" w && lib.hasInfix "both sides apply" w) both.warnings
    && !(off.home.file ? ".config/gm7/app.conf");

  results = {
    concerns-complement-defaults = concernsOk;
    concerns-package-split = concernsPackagesOk;
    concerns-overridable = concernsOverrideOk;
    homebrew-realization-hook = brewOk;
    unrecognised-input-is-unmapped = unrecognisedOk;
    evaluation-is-home-pc = all.reprobuild.intent.evaluation.host == "home-pc";
    packages = packagesOk;
    unmapped = ids all.reprobuild.intent.unmapped == expected.unmapped;
    uncategorized = ids all.reprobuild.intent.uncategorized == expected.uncategorized;
    files = filesOk;
    secret-not-placed = !(all.home.file ? ".ssh/gm5-secret");
    session-variables = all.home.sessionVariables.GM5_EDITOR or null == "nvim";
    session-path =
      all.home.sessionPath == [
        "~/.local/bin"
        "~/gm5/bin"
      ];
    casks = all.reprobuild.intent.homebrew.casks == expected.casks;
    disabled-categories = disabledOk;
    policy = policyOk;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) results);
in
if failed == [ ] then
  pkgs.writeText "reprobuild-lib-home-manager" (builtins.toJSON results)
else
  throw "reprobuild lib-home-manager (${system}): failed: ${builtins.concatStringsSep ", " failed}; unmapped = ${builtins.toJSON all.reprobuild.intent.unmapped}; uncategorized = ${builtins.toJSON all.reprobuild.intent.uncategorized}"
