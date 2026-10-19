# Host facts, Nix side: `reprobuild.lib.homeManagerFacts` and the per-host
# equivalence check `reprobuild.lib.homeEquivalenceCheck`.
#
# reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Measuring
# equivalence (§Host facts, §Identity across ecosystems, §The report); user
# guide docs/user-guide/host-facts.md. The Reprobuild side is `repro home
# facts` (libs/repro_home_apply/src/repro_home_apply/host_facts.nim), which
# writes the same schema; `repro home compare` compares the two.
#
# What a Home Manager configuration contributes, per category:
#
#   packages     `home.packages`, each derivation translated to its canonical
#                package through the Nix contribution catalog
#                (`realizations.lookupCanonical`: the catalog attribute's
#                package name in the configuration's own nixpkgs), plus the
#                caller's Homebrew lists translated through the Homebrew
#                catalog (`lookupBrewToken`). A derivation or token no
#                contribution claims is `unmapped`, never a difference.
#   files        every enabled `home.file` entry (`xdg.configFile` entries are
#                `home.file` entries under the XDG config home), expanded to
#                the files the activation package's `home-files` tree holds,
#                with mode (0755 when executable, else 0644) and SHA-256
#                digest -- except the unit files of declared systemd user
#                units, which are `services` facts.
#   environment  `home.sessionVariables` (`var:NAME`, value) and
#                `home.sessionPath` (`path:ENTRY`).
#   services     `systemd.user.<kind>.<name>` units (`systemd:<name>.<kind>`,
#                enabled = Home Manager links the unit into a `.wants` /
#                `.requires` / `.upholds` directory, digest of the unit
#                file) and enabled `launchd.agents` (`launchd:<Label>`,
#                ProgramArguments, RunAtLoad, KeepAlive).
#
# `dconf.settings` keys and `targets.darwin.defaults` keys are listed as
# `uncategorized` (no category covers them; never compared). Activation
# scripts are imperative code, not declared state, and are not facts.
#
# Digests need the files' bytes, so the facts are a DERIVATION (built for
# the configuration's system), whose `passthru.evaluated` holds what is
# known at evaluation time (everything but file digests) for tests.
{
  realizations,
  brew,
  reproFor,
}:
let
  inherit (builtins)
    attrNames
    concatMap
    elem
    filter
    head
    length
    listToAttrs
    match
    toJSON
    ;

  format = "repro.host-facts";
  schemaVersion = 1;

  # systemd.user option -> unit file suffix (Home Manager modules/systemd.nix).
  unitKinds = {
    services = "service";
    timers = "timer";
    sockets = "socket";
    paths = "path";
    slices = "slice";
    targets = "target";
    mounts = "mount";
    automounts = "automount";
  };

  homebrewKeys = [
    "casks"
    "formulae"
    "masApps"
  ];

  # First occurrence of each `id` wins (one entry per logical id).
  uniqueById =
    entries:
    map (n: n.value) (
      builtins.sort (a: b: a.name < b.name) (
        let
          set = listToAttrs (
            map (e: {
              name = e.id;
              value = e;
            }) entries
          );
        in
        map (n: {
          name = n;
          value = set.${n};
        }) (attrNames set)
      )
    );

  # A launchd boolean key: absent and null both mean false (launchd.plist(5)).
  launchdBool = c: key: if (c.${key} or null) == null then false else c.${key};

  # The builder: turns the evaluated facts plus the `home-files` tree into
  # the final document (file expansion, digests, modes, unit digests). Kept
  # in Python for exact JSON and path handling; the rules are documented in
  # the header above.
  builderScript = ''
    import hashlib, json, os, stat, sys

    spec = json.load(open(sys.argv[1]))
    home_files = spec["homeFiles"]
    roots = sorted(spec["outOfStoreRoots"], key=lambda r: -len(r["prefix"]))

    def resolve(path):
        """The file or directory whose bytes a home path would show, or
        (None, why)."""
        real = os.path.realpath(path)
        if real.startswith("/nix/store/"):
            return real, None
        for r in roots:
            p = r["prefix"].rstrip("/")
            if real == p or real.startswith(p + "/"):
                return os.path.realpath(r["source"] + real[len(p):]), None
        return None, ("an out-of-store link to " + real +
                      ", outside every outOfStoreRoots prefix")

    def digest(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 16), b""):
                h.update(chunk)
        return "sha256:" + h.hexdigest()

    def mode(path):
        return "0755" if os.stat(path).st_mode & stat.S_IXUSR else "0644"

    files = {}
    def add_file(fid, origin, real, why):
        if fid in files:
            return
        if real is None or not os.path.exists(real):
            files[fid] = {"id": fid, "origin": origin + " (content unknown: " +
                          (why or ("no file at " + str(real))) + ")",
                          "mode": None, "digest": None}
        else:
            files[fid] = {"id": fid, "origin": origin, "mode": mode(real),
                          "digest": digest(real)}

    for f in spec["files"]:
        target = f["target"].strip("/")
        origin = "home.file " + target
        real, why = resolve(os.path.join(home_files, target))
        if real is not None and os.path.isdir(real):
            for dirpath, dirnames, filenames in os.walk(real, followlinks=True):
                dirnames.sort()
                for name in sorted(filenames):
                    full = os.path.join(dirpath, name)
                    rel = os.path.relpath(full, real)
                    sub, subwhy = resolve(full)
                    add_file("~/" + target + "/" + rel, origin, sub, subwhy)
        else:
            add_file("~/" + target, origin, real, why)

    services = []
    for s in spec["services"]:
        s = dict(s)
        unit = s.pop("unitTarget", None)
        if unit is not None:
            real, why = resolve(os.path.join(home_files, unit))
            if real is not None and os.path.isfile(real):
                s["digest"] = digest(real)
            else:
                s["digest"] = None
                s["origin"] += " (unit file unknown: " + (why or "not in home-files") + ")"
        services.append(s)

    def by_id(items):
        return sorted(items, key=lambda e: e["id"])

    doc = {
        "format": spec["format"],
        "schemaVersion": spec["schemaVersion"],
        "side": "nix",
        "host": spec["host"],
        "system": spec["system"],
        "categories": {
            "packages": by_id(spec["packages"]),
            "files": by_id(files.values()),
            "environment": by_id(spec["environment"]),
            "services": by_id(services),
        },
        "unmapped": by_id(spec["unmapped"]),
        "uncategorized": by_id(spec["uncategorized"]),
    }
    with open(sys.argv[2], "w") as out:
        json.dump(doc, out, indent=2, sort_keys=True)
        out.write("\n")
  '';

  # reprobuild.lib.homeManagerFacts {
  #   configuration,        a `home-manager.lib.homeManagerConfiguration` result
  #   host,                 the host name the facts are for
  #   homebrew ? { },       { casks ? [ ], formulae ? [ ], masApps ? { } } --
  #                         what the host's Brewfile installs (Home Manager has
  #                         no Homebrew option, so the caller says)
  #   outOfStoreRoots ? { },  { "<absolute prefix>" = <source tree>; } -- an
  #                         out-of-store link (mkOutOfStoreSymlink) into a
  #                         prefix is digested from the source tree given
  #                         for it (e.g. "${homeDirectory}/dotfiles" = self);
  #                         one into no prefix has an unknown digest (null)
  #   system ? <pkgs>,      the target system name the facts are for
  # } -> derivation producing the facts JSON; `.evaluated` holds the
  #      evaluation-time half (no file digests).
  homeManagerFacts =
    {
      configuration,
      host,
      homebrew ? { },
      outOfStoreRoots ? { },
      system ? null,
    }:
    let
      config = configuration.config;
      pkgs = configuration.pkgs;
      lib = pkgs.lib;
      targetSystem = if system != null then system else pkgs.stdenv.hostPlatform.system;
      homeDir = config.home.homeDirectory;

      unknownHomebrewKeys = filter (k: !(elem k homebrewKeys)) (attrNames homebrew);

      # --- packages ----------------------------------------------------------
      index = realizations.reverseIndex pkgs;
      packageResults = map (
        drv:
        let
          r = realizations.lookupCanonical { inherit pkgs drv index; };
          drvName = drv.name or "(unnamed)";
        in
        if r.found then
          {
            package = {
              id = r.name;
              origin = "home.packages ${drvName} (nixpkgs#${r.attribute})";
            }
            // lib.optionalAttrs (drv ? version) { version = drv.version; };
          }
        else
          {
            unmapped = {
              category = "packages";
              id = drvName;
              origin = "home.packages";
              inherit (r) reason;
            };
          }
      ) config.home.packages;

      brewResults =
        kind: tokens:
        map (
          token:
          let
            r = brew.lookupToken { inherit kind token; };
          in
          if r.found then
            {
              package = {
                id = r.name;
                origin = "homebrew ${kind} ${token}";
              };
            }
          else
            {
              unmapped = {
                category = "packages";
                id = "${kind}:${token}";
                origin = "homebrew";
                inherit (r) reason;
              };
            }
        ) tokens;

      masResults = lib.mapAttrsToList (name: appId: {
        unmapped = {
          category = "packages";
          id = "mas:${name}";
          origin = "homebrew mas ${toString appId}";
          reason = "a Mac App Store app; no contribution catalog maps App Store ids to canonical packages";
        };
      }) (homebrew.masApps or { });

      allPackageResults =
        packageResults
        ++ brewResults "cask" (homebrew.casks or [ ])
        ++ brewResults "formula" (homebrew.formulae or [ ])
        ++ masResults;
      pick = attr: list: concatMap (x: if x ? ${attr} then [ x.${attr} ] else [ ]) list;

      # --- services ----------------------------------------------------------
      configRel = lib.removePrefix "${homeDir}/" config.xdg.configHome;
      unitDir = "${configRel}/systemd/user";
      # Home Manager declares systemd units on every platform (tray.target)
      # but writes them on Linux only, and launchd agents on darwin only.
      isDarwinConfig = pkgs.stdenv.hostPlatform.isDarwin;
      userUnits = if isDarwinConfig then { } else config.systemd.user or { };
      units = concatMap (
        kind:
        map (n: "${n}.${unitKinds.${kind}}") (attrNames (userUnits.${kind} or { }))
      ) (attrNames unitKinds);
      enabledFiles = filter (f: f.enable) (builtins.attrValues config.home.file);
      targets = map (f: lib.removePrefix "/" f.target) enabledFiles;
      # `<unitDir>/<unit>` or `<unitDir>/<x>.wants|requires|upholds/<unit>`.
      unitOf =
        target:
        let
          rest = lib.removePrefix "${unitDir}/" target;
          parts = lib.splitString "/" rest;
        in
        if !(lib.hasPrefix "${unitDir}/" target) then
          null
        else if length parts == 1 && elem rest units then
          { inherit rest; link = false; }
        else if
          length parts == 2
          && match ".*\\.(wants|requires|upholds)" (head parts) != null
          && elem (lib.last parts) units
        then
          {
            rest = lib.last parts;
            link = true;
          }
        else
          null;
      linkedUnits = map (t: (unitOf t).rest) (filter (t: (unitOf t).link or false) targets);
      systemdFacts = map (u: {
        id = "systemd:${u}";
        origin = "systemd.user ${u}";
        enabled = elem u linkedUnits;
        unitTarget = "${unitDir}/${u}";
      }) units;
      launchdFacts = lib.mapAttrsToList (
        name: a:
        let
          c = a.config or { };
        in
        {
          id = "launchd:${c.Label or name}";
          origin = "launchd.agents.${name}";
          programArguments =
            if c ? ProgramArguments && c.ProgramArguments != null then
              c.ProgramArguments
            else if (c.Program or null) != null then
              [ c.Program ]
            else
              [ ];
          runAtLoad = launchdBool c "RunAtLoad";
          keepAlive = launchdBool c "KeepAlive";
        }
      ) (
        if isDarwinConfig then lib.filterAttrs (_: a: a.enable or true) (config.launchd.agents or { }) else { }
      );

      # --- files -------------------------------------------------------------
      fileSpecs = map (t: { target = t; }) (filter (t: unitOf t == null) targets);

      # --- environment -------------------------------------------------------
      environment =
        lib.mapAttrsToList (n: v: {
          id = "var:${n}";
          origin = "home.sessionVariables";
          value = toString v;
        }) config.home.sessionVariables
        ++ map (p: {
          id = "path:${pathEntryId p}";
          origin = "home.sessionPath";
        }) config.home.sessionPath;

      # A PATH entry under the home directory is named `~/...` however it
      # spells the home (`$HOME`, `${HOME}`, `~`, the absolute directory),
      # as the Reprobuild producer names it (host_facts.nim,
      # homeRelativePathEntry); other entries are named as written.
      pathEntryId =
        p:
        let
          spellings = [
            "$HOME"
            "\${HOME}"
            "~"
            homeDir
          ];
          home = lib.findFirst (h: p == h || lib.hasPrefix "${h}/" p) null spellings;
        in
        if home == null then
          p
        else if p == home then
          "~"
        else
          "~/" + lib.removePrefix "${home}/" p;

      # --- uncategorized -----------------------------------------------------
      tryAttrs =
        f:
        let
          r = builtins.tryEval f;
        in
        if r.success && builtins.isAttrs r.value then r.value else { };
      # Each is applied only on its own platform (Home Manager's dconf module
      # writes on Linux, `targets.darwin.defaults` on darwin), so only that
      # platform's configuration reports it.
      dconfSettings =
        if isDarwinConfig || !(config.dconf.enable or true) then
          { }
        else
          tryAttrs (config.dconf.settings or { });
      darwinDefaults = if isDarwinConfig then tryAttrs (config.targets.darwin.defaults or { }) else { };
      uncategorized =
        concatMap (
          dir:
          map (key: {
            id = "dconf:${dir}/${key}";
            origin = "dconf.settings";
            reason = "dconf settings are written at activation; no host-facts category covers them";
          }) (attrNames (dconfSettings.${dir} or { }))
        ) (attrNames dconfSettings)
        ++ concatMap (
          domain:
          let
            v = darwinDefaults.${domain};
          in
          map (key: {
            id = "defaults:${domain}/${key}";
            origin = "targets.darwin.defaults";
            reason = "user defaults are written at activation; no host-facts category covers them";
          }) (if builtins.isAttrs v then attrNames v else [ ])
        ) (attrNames darwinDefaults);

      evaluated = {
        inherit format schemaVersion host;
        system = targetSystem;
        homeDirectory = homeDir;
        packages = uniqueById (pick "package" allPackageResults);
        unmapped = uniqueById (pick "unmapped" allPackageResults);
        environment = uniqueById environment;
        services = uniqueById (systemdFacts ++ launchdFacts);
        files = fileSpecs;
        uncategorized = uniqueById uncategorized;
      };

      spec = pkgs.writeText "host-facts-spec-${host}.json" (
        toJSON (
          evaluated
          // {
            homeFiles = "${config.home-files}";
            outOfStoreRoots = lib.mapAttrsToList (prefix: source: {
              inherit prefix;
              source = "${source}";
            }) outOfStoreRoots;
          }
        )
      );
    in
    if unknownHomebrewKeys != [ ] then
      throw "reprobuild.lib.homeManagerFacts: unknown homebrew key(s) ${toString unknownHomebrewKeys} (known: ${toString homebrewKeys})"
    else
      pkgs.runCommand "host-facts-nix-${host}.json"
        {
          nativeBuildInputs = [ pkgs.python3 ];
          builder_py = builderScript;
          passAsFile = [ "builder_py" ];
          passthru = { inherit evaluated; };
        }
        ''
          python3 "$builder_pyPath" ${spec} "$out"
        '';

  # The Reprobuild side: `repro home facts` of `profileDir` for `host` and
  # `system`, run by the packaged `repro` in the build sandbox (it plans
  # against private home and state directories of its own).
  reprobuildFacts =
    {
      pkgs,
      repro,
      profileDir,
      host,
      system,
    }:
    pkgs.runCommand "host-facts-reprobuild-${host}.json"
      {
        profile = profileDir;
        inherit host system;
        nativeBuildInputs = [ repro ];
      }
      ''
        export HOME="$TMPDIR/home"
        unset REPRO_HOST
        mkdir -p "$HOME"
        cp -R "$profile" "$TMPDIR/profile"
        chmod -R u+w "$TMPDIR/profile"
        repro home facts --profile-dir "$TMPDIR/profile" --host "$host" \
          --target "$system" --output "$out"
      '';

  # reprobuild.lib.homeEquivalenceCheck {
  #   configuration, host, profileDir,   as for the two producers
  #   allowlist ? null,                  a TOML allowlist (every row needs a
  #                                      reason; see `repro home compare`)
  #   homebrew ? { }, outOfStoreRoots ? { },   passed to homeManagerFacts
  #   name ? "home-equivalence-<host>",
  #   repro ? <this flake's repro for the configuration's system>,
  # } -> a derivation that builds both facts documents and runs
  #      `repro home compare`; it fails (with the report on the log) when the
  #      comparison exits non-zero. $out holds nix.json, reprobuild.json,
  #      report.txt and report.json.
  homeEquivalenceCheck =
    {
      configuration,
      host,
      profileDir,
      allowlist ? null,
      homebrew ? { },
      outOfStoreRoots ? { },
      name ? "home-equivalence-${host}",
      repro ? null,
    }:
    let
      pkgs = configuration.pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      reproPkg = if repro != null then repro else reproFor system;
      nixFacts = homeManagerFacts {
        inherit
          configuration
          host
          homebrew
          outOfStoreRoots
          ;
      };
      reproFacts = reprobuildFacts {
        inherit
          pkgs
          profileDir
          host
          system
          ;
        repro = reproPkg;
      };
      allowArgs = if allowlist == null then "" else "--allow ${allowlist}";
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ reproPkg ];
        passthru = { inherit nixFacts reproFacts; };
      }
      ''
        mkdir -p "$out"
        cp ${nixFacts} "$out/nix.json"
        cp ${reproFacts} "$out/reprobuild.json"
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        status=0
        repro home compare --facts "$out/nix.json" --facts "$out/reprobuild.json" \
          ${allowArgs} > "$out/report.txt" 2>&1 || status=$?
        repro home compare --facts "$out/nix.json" --facts "$out/reprobuild.json" \
          ${allowArgs} --format json > "$out/report.json" 2>/dev/null || true
        cat "$out/report.txt"
        if [ "$status" -ne 0 ]; then
          echo "home equivalence for ${host}: repro home compare exited $status" >&2
          exit "$status"
        fi
      '';
in
{
  inherit
    homeManagerFacts
    reprobuildFacts
    homeEquivalenceCheck
    format
    schemaVersion
    ;
}
