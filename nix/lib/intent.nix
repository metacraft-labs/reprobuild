# `reprobuild.lib.readIntent` -- a `repro home export` document read by Nix,
# from a committed snapshot or by import-from-derivation, and evaluated for a
# target system and host.
#
# The document is Reprobuild's: `repro home export` compiles the profile,
# expands its data files and probes every target platform (reprobuild-pm spec
# Gradual-Nix-To-Reprobuild-Migration.md §Exporting evaluated intent to Nix,
# schema in §Export schema (version 4 since GM10); public reference
# docs/user-guide/home-export.md). Nix only reads it. Two consumption modes
# (§Consumption modes), one consumer code path:
#
#   * snapshot -- `builtins.fromJSON` of a committed export. No Reprobuild
#     binary at evaluation; works under restricted evaluation and on every
#     evaluator.
#   * IFD -- a derivation runs the packaged `repro home export` in the build
#     sandbox (no wrapping: the installed package compiles profiles on its
#     own, GM1/GM1l) and Nix imports its output. The derivation is built for
#     the EVALUATOR's system (`buildSystem`), never the target's: the export is
#     platform-neutral (§Platform-neutral intent), so a Linux evaluator
#     describes an aarch64-darwin host by building on Linux.
#
# Either way the document then goes through the same `evaluate`, which
# applies the planner's rules for `system` and `host` the way
# `evaluateHomeExport` (`repro_cli_support/home_export.nim`, behind
# `repro home export --target`) does:
#
#   * refusal: a document is refused for a target whose `platforms` entry is
#     not `same`, unless the target is `provenance.compile.target` (a
#     document always describes the platform that compiled it); an unknown
#     `format` or `schemaVersion` is refused; so is an intent that still names
#     data files (an export always carries them expanded);
#   * activities: `default` plus the host's `hosts:` entry, reported in
#     declaration order (`enabledActivitiesFor`, `hostSelection`). A host the
#     profile's `hosts:` registry does not name is refused when the profile
#     has a registry (`hostRefusalReason`; spec Open question 6, answered by
#     GM8: an unknown host is an error, and `"<host>": [default]` is the
#     explicit opt-in for `default` alone); a profile without one selects
#     `default` everywhere;
#   * packages: the `packageRef`s of enabled activities, a `whenGuard`'s only
#     when its predicate holds, one per package (first occurrence wins);
#     sorted by name (the planner's order is a topological sort over
#     extractor edges with ties broken by name, which only the resolver can
#     compute -- consumers should not depend on order);
#   * resources and config overrides: those whose `guard` holds, in intent
#     order; a resource that belongs to an activity (`activity`, GM9) only
#     when the host's enabled activities include it
#     (`applicableResourceEntries`). A resource naming an activity the
#     intent does not declare is refused, as the planner refuses it
#     (`profileIntentToHomeProfile`).
#   * applies: the concerns the host's `hosts:` entry declares Reprobuild
#     applies (`intent.hostApplies`, Gradual-Nix-To-Reprobuild-Migration.md
#     §Concern-scoped apply), absent when it declares none. A declaration
#     naming a concern the document's `concerns.names` does not list -- or a
#     declaration in a document without `concerns` -- is refused: the
#     library cannot tell what such a name covers;
#   * package concerns: for a host that declares, every package carries
#     `concern` (`applications` / `packages`) and `resolved`, read from the
#     classification Reprobuild computed for `system`
#     (`concerns.packages.<system>`: the references whose selection places an
#     application there, and those that resolve to nothing there; keyed
#     `name`, or `name@version` for a pinned reference). Nothing is
#     classified here: which package is an application is Reprobuild's
#     realization selection (P1, P6). A document without a row for `system`
#     is refused.
#   * profile bin: for a host that declares, Reprobuild applies `packages`
#     or `applications` (whose launchers it writes into its profile bin
#     directory) and does not apply `environment`, `profileBin` -- the
#     directory's location for `system` (`concerns.profileBin.<system>`:
#     `{ base, path }`, base `home`, `xdgStateHome` or `localAppData`) -- so
#     the Nix side, which writes the shell environment there, puts it on
#     `PATH` (`profileBinPath`; Gradual-Nix-To-Reprobuild-Migration.md
#     §Concern-scoped apply, "The profile's commands"). Absent otherwise. A
#     document without that row is refused for such a host.
#   * system: who manages the host's system scope (GM10;
#     Gradual-Nix-To-Reprobuild-Migration.md §Hosts, feature 2) --
#     `{ managed = "elsewhere"; managedBy = <pointer> | null; }` when the
#     host's `hosts:` entry says `system: managedElsewhere[(...)]`
#     (`intent.systemManagedElsewhere`), `{ managed = "here"; managedBy =
#     null; }` otherwise. Always present (`systemManagementOf`, also
#     exposed as `reprobuild.lib.hostSystemManagement`, which needs no
#     target system). A malformed entry, or one for a host the registry does
#     not declare, is refused, never read as "here".
#
# Resource scope: the home planner refuses a home profile that declares a
# resource it does not apply (a system-scope kind such as `fs.systemFile`),
# so `repro home export` never emits one. This evaluation therefore needs no
# scope list of its own (a second one is what the spec's §Principles P6 rules
# out): it keeps every resource whose guard holds, and a document that does
# carry a kind the Home Manager module does not know -- hand-edited, or
# newer than this library -- reaches the module as `unmapped`, never dropped.
{
  predicate,
  platforms,
  hostSelection,
}:
let
  inherit (builtins)
    concatMap
    elem
    filter
    foldl'
    fromJSON
    readFile
    toJSON
    ;

  format = "repro.home.export";
  knownSchemaVersions = [ 4 ];

  # Every condition under which a consumer must not use the document for
  # `system`, as a message, or null. Shared by both modes.
  refusalReason =
    doc: system:
    let
      compileTarget = doc.provenance.compile.target or null;
      entry = doc.platforms.${system} or null;
      probe = doc.provenance.compile.probe.${system} or null;
    in
    if (doc.format or null) != format then
      "the document's format is ${toJSON (doc.format or null)}, not \"${format}\": it is not a `repro home export` document"
    else if !(elem (doc.schemaVersion or null) knownSchemaVersions) then
      "the document's schemaVersion is ${
        toJSON (doc.schemaVersion or null)
      }; this library reads ${toJSON knownSchemaVersions} -- regenerate the export with the repro this reprobuild flake pins, or update the flake"
    else if !(builtins.elem system platforms.systems) then
      "unknown target system '${system}' (known: ${builtins.concatStringsSep ", " platforms.systems})"
    else if (doc.intent.dataFiles or [ ]) != [ ] then
      "the document's intent still names data files (${builtins.concatStringsSep ", " doc.intent.dataFiles}); an export carries them expanded -- re-export"
    else if system == compileTarget then
      null
    else if entry == "same" then
      null
    else if entry == "differs" then
      "this export was compiled on ${toString compileTarget}, and evaluated for ${system} the profile declares a different intent: a compile-time `when defined(...)` decided part of it for ${toString compileTarget}. Select platforms with runtime predicates (`when macos():`) so one export describes every platform, or export on ${system}"
    else
      "this export was compiled on ${toString compileTarget}, and the platform probe could not evaluate the profile for ${system} (${
        if probe == null then "platforms.${system} is ${toJSON entry}" else probe
      }). Export on ${system} instead";

  # Why `host` cannot be selected from `doc`, or null: the planner's rule
  # (`enabledActivitiesFor` raising `EUndeclaredHost`; hosts.nix).
  hostRefusalReason = doc: host: hostSelection.undeclaredHostReason (doc.intent.hosts or { }) host;

  holdsFor = facts: guard: predicate.holds facts guard;

  # Who manages `host`'s system scope, from a validated document's intent
  # (`systemManagedElsewhere`, export schema 4; `repro_profile/host_system`
  # `systemManagementFor` on the Reprobuild side). Callers check the host
  # first (`hostRefusalReason`).
  systemManagementOf =
    doc: host:
    let
      table = doc.intent.systemManagedElsewhere or { };
      hosts = doc.intent.hosts or { };
      bad = builtins.filter (
        h:
        let
          v = table.${h};
        in
        !(builtins.isAttrs v)
        || !(v ? managedBy)
        || !(v.managedBy == null || (builtins.isString v.managedBy && v.managedBy != ""))
      ) (builtins.attrNames table);
      undeclared = builtins.filter (h: !(hosts ? ${h})) (builtins.attrNames table);
      entry = table.${host} or null;
    in
    if !(builtins.isAttrs table) then
      throw "reprobuild.lib: the document's intent.systemManagedElsewhere is not an object (host -> { managedBy })"
    else if bad != [ ] then
      throw "reprobuild.lib: intent.systemManagedElsewhere entries ${toJSON bad} are malformed: each must be { managedBy = <non-empty string> | null; }"
    else if undeclared != [ ] then
      throw "reprobuild.lib: intent.systemManagedElsewhere names host(s) ${toJSON undeclared}, which the profile's hosts: registry does not declare"
    else if entry == null then
      {
        managed = "here";
        managedBy = null;
      }
    else
      {
        managed = "elsewhere";
        inherit (entry) managedBy;
      };

  # `reprobuild.lib.hostSystemManagement { host, snapshot ? null, document ? null }`
  # -> `{ host, managed, managedBy }`: who manages `host`'s system scope,
  # without evaluating any target system (a system switch asks this before it
  # knows or cares which packages the host gets). Refuses a document of
  # another format or schema version and a host the registry does not
  # declare, as `readIntent` does.
  hostSystemManagement =
    {
      host,
      snapshot ? null,
      document ? null,
    }:
    let
      doc =
        if document != null then
          document
        else if snapshot != null then
          fromJSON (readFile snapshot)
        else
          throw "reprobuild.lib.hostSystemManagement: pass `snapshot` (a committed export) or `document`";
      formatReason =
        if (doc.format or null) != format then
          "the document's format is ${toJSON (doc.format or null)}, not \"${format}\""
        else if !(elem (doc.schemaVersion or null) knownSchemaVersions) then
          "the document's schemaVersion is ${toJSON (doc.schemaVersion or null)}; this library reads ${toJSON knownSchemaVersions} -- regenerate the export with the repro this reprobuild flake pins, or update the flake"
        else
          null;
      reason = if formatReason != null then formatReason else hostRefusalReason doc host;
    in
    if reason != null then
      throw "reprobuild.lib.hostSystemManagement: cannot read host ${host}: ${reason}"
    else
      { inherit host; } // systemManagementOf doc host;

  # The packages an activity body contributes on `facts`
  # (`collectPackagesFromBody`). A guard's body holds package references only;
  # anything else is refused rather than skipped.
  bodyPackages =
    facts: activity: body:
    concatMap (
      el:
      if el.kind == "packageRef" then
        [ (el // { inherit activity; }) ]
      else if el.kind == "whenGuard" then
        (
          if holdsFor facts el.predicate then
            map (
              inner:
              if inner.kind == "packageRef" then
                inner // { inherit activity; }
              else
                throw "reprobuild: activity `${activity}`: a `${inner.kind}` inside a `whenGuard` is not something this library (or the planner) evaluates"
            ) el.body
          else
            [ ]
        )
      else
        throw "reprobuild: activity `${activity}`: unknown activity element kind `${toString (el.kind or null)}`"
    ) body;

  # Evaluate a validated document for `system` and `host`. Returns the
  # `evaluation` object `repro home export --target` prints (see the module
  # header: packages are sorted by name).
  evaluate =
    doc: system: host:
    let
      selectedHost = if host != null then host else doc.selection.host;
      # The host first, as `repro home export` does: the export of an
      # undeclared host fails before any target is evaluated.
      reason =
        let
          r = hostRefusalReason doc selectedHost;
        in
        if r != null then r else refusalReason doc system;
      facts = platforms.factsFor system selectedHost;
      intent = doc.intent;
      enabled = hostSelection.enabledActivities (intent.hosts or { }) selectedHost;
      declared = map (a: a.name) intent.activities;
      activities = filter (a: elem a enabled) declared;
      raw = concatMap (
        a: if elem a.name enabled then bodyPackages facts a.name a.body else [ ]
      ) intent.activities;
      unique =
        (foldl'
          (
            acc: p:
            if acc.seen ? ${p.name} then
              acc
            else
              {
                seen = acc.seen // {
                  ${p.name} = true;
                };
                list = acc.list ++ [ p ];
              }
          )
          {
            seen = { };
            list = [ ];
          }
          raw
        ).list;
      packages = builtins.sort (a: b: a.name < b.name) (
        map (p: {
          inherit (p) name activity;
          version = p.version or "";
          binaries = p.binaries or [ ];
        }) unique
      );
      hostApplies = intent.hostApplies or { };
      knownConcerns = doc.concerns.names or null;
      applies = hostApplies.${selectedHost} or null;
      unknownConcerns = if applies == null || knownConcerns == null then [ ] else filter (c: !(elem c knownConcerns)) applies;
      # Reprobuild's per-package classification for this system, read only for
      # a host that declares (`withConcern`).
      classification =
        doc.concerns.packages.${system}
          or (throw "reprobuild.lib.readIntent: host ${selectedHost} declares the concerns Reprobuild applies, but the document carries no package classification for ${system} (concerns.packages.${system}); it was produced by a repro that does not publish one -- re-export");
      packageKey = p: if p.version == "" then p.name else "${p.name}@${p.version}";
      # Reprobuild writes launchers (`packages` / `applications`) and Nix
      # writes the shell environment: the launchers' directory is Nix's to
      # put on PATH.
      needsProfileBin =
        applies != null && (elem "packages" applies || elem "applications" applies) && !(elem "environment" applies);
      profileBin =
        let
          location = doc.concerns.profileBin.${system} or null;
        in
        if location == null || !(location ? base) || !(location ? path) then
          throw "reprobuild.lib.readIntent: host ${selectedHost} leaves `environment` to Nix while Reprobuild applies its launchers, but the document does not say where they are for ${system} (concerns.profileBin.${system}); it was produced by a repro that does not publish it -- re-export"
        else
          { inherit (location) base path; };
      withConcern =
        p:
        p
        // {
          concern = if elem (packageKey p) classification.applications then "applications" else "packages";
          resolved = !(elem (packageKey p) classification.unresolved);
        };
      # GM9: an activity-scoped resource applies only where its activity is
      # enabled; `null` (or absent) is profile-wide. An activity the intent
      # does not declare is refused, never read as profile-wide.
      resourceInSelection =
        r:
        let
          activity = r.activity or null;
        in
        if activity == null then
          true
        else if !(elem activity declared) then
          throw "reprobuild.lib.readIntent: resource `${toString (r.address or "")}` belongs to activity `${toString activity}`, which the profile does not declare (declared: ${builtins.concatStringsSep ", " declared})"
        else
          elem activity enabled;
    in
    if reason != null then
      throw "reprobuild.lib.readIntent: cannot evaluate this export for ${system}: ${reason}"
    else if hostApplies != { } && knownConcerns == null then
      throw "reprobuild.lib.readIntent: the document's intent declares the concerns Reprobuild applies per host (hostApplies) but carries no `concerns` classification; it was not produced by `repro home export` -- re-export"
    else if unknownConcerns != [ ] then
      throw "reprobuild.lib.readIntent: host ${selectedHost} declares unknown concern(s) ${toJSON unknownConcerns} (known: ${toJSON knownConcerns})"
    else
      {
        target = system;
        host = selectedHost;
        inherit activities;
        packages = if applies == null then packages else map withConcern packages;
        resources = filter (r: resourceInSelection r && holdsFor facts (r.guard or null)) (
          intent.resources or [ ]
        );
        configOverrides = filter (o: holdsFor facts (o.guard or null)) (intent.configOverrides or [ ]);
        system = systemManagementOf doc selectedHost;
      }
      // (if applies == null then { } else { inherit applies; })
      // (if needsProfileBin then { inherit profileBin; } else { });

  # The derivation IFD mode imports: `repro home export` of `profileDir` for
  # `host`, run by the packaged `repro` in the build sandbox with a private
  # HOME and state directory. The profile is copied to a writable directory
  # (the compile stages its configuration beside it). `--target` is not
  # passed: the evaluation is `evaluate`'s, in both modes.
  #
  # `packagesCatalog` (a `reprobuild-packages` checkout, or null) is where the
  # export's package classification (`concerns.packages`) finds the package
  # definitions that live in that catalog: the sandbox has no workspace to
  # find it beside, so without it every such package is `unresolved` there.
  # It is passed as `$REPROBUILD_PACKAGES_ROOT`, the only place `repro` then
  # looks.
  exportDerivation =
    {
      pkgs,
      repro,
      profileDir,
      host,
      packagesCatalog ? null,
    }:
    let
      safeHost = builtins.replaceStrings [ " " "/" ] [ "-" "-" ] host;
    in
    pkgs.runCommand "repro-home-export-${safeHost}.json"
      (
        {
          profile = profileDir;
          inherit host;
          nativeBuildInputs = [ repro ];
        }
        // (if packagesCatalog == null then { } else { REPROBUILD_PACKAGES_ROOT = packagesCatalog; })
      )
      ''
        export HOME="$TMPDIR/home"
        export REPRO_HOME_STATE_DIR="$TMPDIR/state"
        unset REPRO_HOST
        mkdir -p "$HOME"
        cp -R "$profile" "$TMPDIR/profile"
        chmod -R u+w "$TMPDIR/profile"
        repro home export --profile-dir "$TMPDIR/profile" --host "$host" --format json > "$out"
      '';
  # The absolute directory an evaluation's `profileBin` names, for a user
  # whose home directory is `homeDirectory` (and XDG state directory
  # `xdgStateHome`, by default `<home>/.local/state`, as Reprobuild resolves
  # it when $XDG_STATE_HOME is unset), or null when the evaluation carries
  # none (the host leaves its launchers to nobody, or Reprobuild writes its
  # environment itself). `localAppData` is a Windows directory no Nix
  # consumer manages, and is refused. Reprobuild resolves the state
  # directory from $REPRO_HOME_STATE_DIR first; a host that sets it must
  # put `<it>/current/bin` on PATH itself.
  profileBinPath =
    {
      evaluation,
      homeDirectory,
      xdgStateHome ? "${homeDirectory}/.local/state",
    }:
    let
      location = evaluation.profileBin or null;
    in
    if location == null then
      null
    else if location.base == "home" then
      "${homeDirectory}/${location.path}"
    else if location.base == "xdgStateHome" then
      "${xdgStateHome}/${location.path}"
    else
      throw "reprobuild.lib.profileBinPath: the profile bin directory of ${evaluation.host} on ${evaluation.target} is under `${location.base}`, which a Nix consumer does not manage";
in
{
  inherit
    profileBinPath
    evaluate
    refusalReason
    hostRefusalReason
    exportDerivation
    format
    knownSchemaVersions
    hostSystemManagement
    ;

  # reprobuild.lib.readIntent { host, system, snapshot ? null, profileDir ? null,
  #                             buildSystem ? <evaluator>, repro ? <pinned>,
  #                             packagesCatalog ? null }
  #
  # Snapshot mode when `snapshot` (a path to a committed export) is given,
  # IFD mode otherwise (`profileDir` required; `packagesCatalog`, a
  # `reprobuild-packages` checkout, lets the sandboxed export classify the
  # packages that catalog defines -- see `exportDerivation`). Returns
  # `{ mode, document, evaluation }`, `evaluation` being what
  # `repro home export --target ${system}` reports for `host`. Throws when
  # the document cannot describe `system` (see `refusalReason`).
  mkReadIntent =
    {
      pkgsFor,
      reproFor,
    }:
    {
      host,
      system,
      snapshot ? null,
      profileDir ? null,
      buildSystem ? builtins.currentSystem or null,
      repro ? null,
      packagesCatalog ? null,
    }:
    let
      mode = if snapshot != null then "snapshot" else "ifd";
      document =
        if snapshot != null then
          fromJSON (readFile snapshot)
        else if profileDir == null then
          throw "reprobuild.lib.readIntent: pass `snapshot` (a committed export) or `profileDir` (IFD mode)"
        else if buildSystem == null then
          throw "reprobuild.lib.readIntent: IFD mode needs `buildSystem`, the system that runs `repro home export` (the evaluator's, not the target's); pure evaluation does not expose builtins.currentSystem"
        else
          fromJSON (
            readFile (exportDerivation {
              pkgs = pkgsFor buildSystem;
              repro = if repro != null then repro else reproFor buildSystem;
              inherit profileDir host packagesCatalog;
            })
          );
      reason =
        let
          r = hostRefusalReason document host;
        in
        if r != null then r else refusalReason document system;
    in
    # Refused as a whole, not only on access to `evaluation`: a consumer that
    # reads `document` for a target it does not describe is as wrong as one
    # that reads the evaluation.
    if reason != null then
      throw "reprobuild.lib.readIntent: cannot evaluate this export for ${system}: ${reason}"
    else
      {
        inherit mode document;
        evaluation = evaluate document system host;
      };
}
