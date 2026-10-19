# The flake check `lib-host-facts`: `reprobuild.lib.homeManagerFacts` over a
# real Home Manager configuration (devops-modules' `home-manager-unstable`,
# as `lib-home-manager` uses) that declares something in every host-facts
# category, on this check's system.
#
# Two halves, as the producer has two:
#
#   * EVALUATION (decided while evaluating, so `--all-systems` checks every
#     system from any evaluator): the `evaluated` facts -- packages through
#     the real Nix and Homebrew catalogs (an overridden derivation maps by
#     package name; an unclaimed derivation, an unknown cask and a Mac App
#     Store app are unmapped with reasons), environment, services per
#     platform, the file targets without the systemd unit files, the
#     uncategorized dconf keys, and the refusal of an unknown `homebrew` key.
#   * BUILD (the derivation, built on this check's system): the document
#     itself -- its schema fields, every file's id, mode and SHA-256 digest
#     against digests computed independently (`sha256sum` of the literal
#     bytes, recorded below), a recursive directory expanded per file, an
#     out-of-store link digested from the mapped root and one into no root
#     reported with a null digest, the unit digest and enablement.
{
  lib,
  pkgs,
  system,
  homeManager,
  reprobuildLib,
  root,
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
  homeDir = if isDarwin then "/Users/gm6" else "/home/gm6";
  tree = root + "/tests/fixtures/host-facts/hm-tree";

  configuration = homeManager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      (
        { config, ... }:
        {
          home = {
            username = "gm6";
            homeDirectory = homeDir;
            stateVersion = "25.05";
            packages = [
              pkgs.bash
              # A different derivation (an override adds an attribute), the
              # same package name: still the canonical `cmake`.
              (pkgs.cmake.overrideAttrs (_: {
                GM6_OVERRIDE = "1";
              }))
              # No catalog attribute has the package name `hello`.
              pkgs.hello
            ];
            sessionVariables.GM6_EDITOR = "nvim";
            # Three spellings: `$HOME/...` and the absolute home directory
            # are both named `~/...`; a path outside the home as written.
            sessionPath = [
              "$HOME/.local/bin"
              "${homeDir}/gm6/bin"
              "/opt/gm6/bin"
            ];
            file = {
              "gm6/plain.txt".text = "plain\n";
              "gm6/run.sh" = {
                text = "#!/bin/sh\nexit 0\n";
                executable = true;
              };
              "gm6/tree" = {
                source = tree;
                recursive = true;
              };
              "gm6/mapped.txt".source = config.lib.file.mkOutOfStoreSymlink "${homeDir}/checkout/mapped.txt";
              "gm6/elsewhere.txt".source = config.lib.file.mkOutOfStoreSymlink "/srv/gm6/elsewhere.txt";
            };
          };
          xdg.configFile."gm6/app.conf".text = "answer = 42\n";
        }
      )
      (lib.optionalAttrs isLinux {
        systemd.user.services.gm6 = {
          Unit.Description = "gm6";
          Service.ExecStart = "/bin/true";
          Install.WantedBy = [ "default.target" ];
        };
        systemd.user.timers.gm6t = {
          Unit.Description = "gm6 timer";
          Timer.OnCalendar = "daily";
        };
        dconf.settings."org/gm6".answer = 42;
      })
      (lib.optionalAttrs isDarwin {
        launchd.agents.gm6 = {
          enable = true;
          config = {
            Label = "org.gm6.agent";
            ProgramArguments = [
              "/bin/echo"
              "gm6"
            ];
            RunAtLoad = true;
          };
        };
      })
    ];
  };

  facts = reprobuildLib.homeManagerFacts {
    inherit configuration;
    host = "gm6-host";
    homebrew = {
      casks = [
        "visual-studio-code"
        "gm6-no-such-cask"
      ];
      masApps.amphetamine = 937984704;
    };
    outOfStoreRoots."${homeDir}/checkout" = tree;
  };
  ev = facts.evaluated;
  ids = map (e: e.id);
  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  unitDir = ".config/systemd/user";
  targets = map (f: f.target) ev.files;

  results = {
    schema = ev.format == "repro.host-facts" && ev.schemaVersion == 1 && ev.system == system;
    # bash and cmake through the Nix catalog; vscode through the cask.
    packages = ids ev.packages == [
      "bash"
      "cmake"
      "vscode"
    ];
    package-origin = lib.hasInfix "nixpkgs#cmake" (lib.findFirst (e: e.id == "cmake") { origin = ""; } ev.packages)
    .origin;
    # Vacuity of the override case: it really is another derivation.
    override-is-another-derivation =
      let
        overridden = builtins.filter (p: p ? GM6_OVERRIDE) configuration.config.home.packages;
      in
      builtins.length overridden == 1 && (builtins.head overridden).drvPath != pkgs.cmake.drvPath;
    unmapped =
      let
        u = ids ev.unmapped;
      in
      builtins.elem "cask:gm6-no-such-cask" u
      && builtins.elem "mas:amphetamine" u
      && builtins.elem pkgs.hello.name u
      && builtins.all (e: e.category == "packages" && e.reason != "") ev.unmapped;
    # Home Manager adds variables of its own (LOCALE_ARCHIVE_2_27 on Linux).
    environment =
      builtins.elem "path:~/.local/bin" (ids ev.environment)
      && builtins.elem "path:~/gm6/bin" (ids ev.environment)
      && builtins.elem "path:/opt/gm6/bin" (ids ev.environment)
      && !(builtins.any (lib.hasPrefix "path:$HOME") (ids ev.environment))
      && builtins.elem "var:GM6_EDITOR" (ids ev.environment);
    variable-value = (builtins.head (builtins.filter (e: e.id == "var:GM6_EDITOR") ev.environment)).value == "nvim";
    services =
      # Home Manager declares units of its own (tray.target) beside ours.
      if isLinux then
        let
          byId = builtins.listToAttrs (
            map (s: {
              name = s.id;
              value = s;
            }) ev.services
          );
        in
        (byId."systemd:gm6.service".enabled or false)
        && !(byId."systemd:gm6t.timer".enabled or true)
        && builtins.all (s: lib.hasPrefix "systemd:" s.id) ev.services
      else
        ids ev.services == [ "launchd:org.gm6.agent" ]
        && (builtins.head ev.services).programArguments == [
          "/bin/echo"
          "gm6"
        ]
        && (builtins.head ev.services).runAtLoad
        && !(builtins.head ev.services).keepAlive;
    # The unit files (and wants links) are services facts, not files.
    files-exclude-units = !(builtins.any (t: lib.hasPrefix unitDir t) targets);
    files-targets = builtins.all (t: builtins.elem t targets) [
      "gm6/plain.txt"
      "gm6/run.sh"
      "gm6/tree"
      "gm6/mapped.txt"
      "gm6/elsewhere.txt"
      ".config/gm6/app.conf"
    ];
    # dconf keys on Linux only; on darwin only user defaults (Home Manager
    # sets some of its own there).
    uncategorized =
      if isLinux then
        ids ev.uncategorized == [ "dconf:org/gm6/answer" ]
      else
        builtins.all (e: lib.hasPrefix "defaults:" e.id) ev.uncategorized;
    unknown-homebrew-key-refused = fails (reprobuildLib.homeManagerFacts {
      inherit configuration;
      host = "gm6-host";
      homebrew.taps = [ "gm6/tap" ];
    });
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) results);

  # sha256sum of the literal bytes (computed with coreutils, 2026-10-15).
  expectedFiles = {
    "~/gm6/plain.txt" = {
      mode = "0644";
      digest = "sha256:dacf36547c7774a0a170806363b5d412991fbc0d6260b2c00b1d3a80a816c23f";
    };
    "~/gm6/run.sh" = {
      mode = "0755";
      digest = "sha256:306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb";
    };
    "~/gm6/tree/mapped.txt" = {
      mode = "0644";
      digest = "sha256:20d3ed2486bb308a488b0973ef7b83e4d5e676ab443cd1056f7c59c36f1d3453";
    };
    "~/gm6/tree/bin/tool" = {
      mode = "0755";
      digest = "sha256:bf664cf84f00f6ed76164c8457fdeaf8e4dee547226e9ffcf8274e2d2246fed9";
    };
    "~/gm6/mapped.txt" = {
      mode = "0644";
      digest = "sha256:20d3ed2486bb308a488b0973ef7b83e4d5e676ab443cd1056f7c59c36f1d3453";
    };
    "~/gm6/elsewhere.txt" = {
      mode = null;
      digest = null;
    };
    "~/.config/gm6/app.conf" = {
      mode = "0644";
      digest = "sha256:0a775022744f64c352863f165f2e125898419999bc57c83204772036d0ef6b2e";
    };
  };
  expectedJson = pkgs.writeText "gm6-expected-files.json" (builtins.toJSON expectedFiles);
in
if failed != [ ] then
  throw "reprobuild lib-host-facts (${system}): failed: ${builtins.concatStringsSep ", " failed}; evaluated = ${builtins.toJSON (builtins.removeAttrs ev [ "files" ])}"
else
  pkgs.runCommand "reprobuild-lib-host-facts"
    {
      nativeBuildInputs = [ pkgs.jq ];
      inherit facts;
      expected = expectedJson;
      isLinux = if isLinux then "1" else "";
    }
    ''
      fail() { echo "lib-host-facts: $*" >&2; jq . "$facts" >&2; exit 1; }
      jq -e '.format == "repro.host-facts" and .schemaVersion == 1 and .side == "nix" and .host == "gm6-host"' "$facts" >/dev/null || fail "header"
      # Every expected file, with exactly its mode and digest.
      for id in $(jq -r 'keys[]' "$expected"); do
        want=$(jq -cS --arg id "$id" '.[$id]' "$expected")
        got=$(jq -cS --arg id "$id" '[.categories.files[] | select(.id == $id) | {mode, digest}] | .[0]' "$facts")
        [ "$want" = "$got" ] || fail "file $id: want $want, got $got"
      done
      # The out-of-store link into no mapped root says why its content is unknown.
      jq -e '.categories.files[] | select(.id == "~/gm6/elsewhere.txt") | .origin | contains("outside every outOfStoreRoots prefix")' "$facts" >/dev/null \
        || fail "elsewhere.txt origin"
      # The recursive directory is expanded per file, never reported as a directory.
      jq -e '[.categories.files[].id] | index("~/gm6/tree") == null' "$facts" >/dev/null || fail "tree not expanded"
      if [ -n "$isLinux" ]; then
        # The unit digest is the unit file Home Manager writes; it is no file entry.
        jq -e '.categories.services[] | select(.id == "systemd:gm6.service") | .enabled == true and (.digest | startswith("sha256:"))' "$facts" >/dev/null \
          || fail "unit"
        jq -e '[.categories.files[].id | select(contains("systemd/user"))] | length == 0' "$facts" >/dev/null || fail "unit files leaked into files"
      fi
      jq -e '.categories | to_entries | all(.value | length > 0)' "$facts" >/dev/null || fail "an empty category"
      cp "$facts" "$out"
    ''
