# `reprobuild.lib.readIntent` -- a `repro home export` document read by Nix,
# from a committed snapshot or by import-from-derivation, and evaluated for a
# target system and host.
#
# The document is Reprobuild's: `repro home export` compiles the profile,
# expands its data files and probes every target platform (reprobuild-pm spec
# Gradual-Nix-To-Reprobuild-Migration.md §Exporting evaluated intent to Nix,
# schema in §Export schema, version 2; public reference
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
#     declaration order (`enabledActivitiesFor`, `hostSelection`);
#   * packages: the `packageRef`s of enabled activities, a `whenGuard`'s only
#     when its predicate holds, one per package (first occurrence wins);
#     sorted by name (the planner's order is a topological sort over
#     extractor edges with ties broken by name, which only the resolver can
#     compute -- consumers should not depend on order);
#   * resources and config overrides: those whose `guard` holds, in intent
#     order.
#
# Resource scope: the home planner refuses a home profile that declares a
# resource it does not apply (a system-scope kind such as `fs.systemFile`),
# so `repro home export` never emits one. This evaluation therefore needs no
# scope list of its own (a second one is what the spec's §Principles P6 rules
# out): it keeps every resource whose guard holds, and a document that does
# carry a kind the Home Manager module does not know -- hand-edited, or
# newer than this library -- reaches the module as `unmapped`, never dropped.
{ predicate, platforms }:
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
  knownSchemaVersions = [ 2 ];

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

  holdsFor = facts: guard: predicate.holds facts guard;

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
      reason = refusalReason doc system;
      selectedHost = if host != null then host else doc.selection.host;
      facts = platforms.factsFor system selectedHost;
      intent = doc.intent;
      enabled = [ "default" ] ++ (intent.hosts.${selectedHost} or [ ]);
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
    in
    if reason != null then
      throw "reprobuild.lib.readIntent: cannot evaluate this export for ${system}: ${reason}"
    else
      {
        target = system;
        host = selectedHost;
        inherit activities packages;
        resources = filter (r: holdsFor facts (r.guard or null)) (intent.resources or [ ]);
        configOverrides = filter (o: holdsFor facts (o.guard or null)) (intent.configOverrides or [ ]);
      };

  # The derivation IFD mode imports: `repro home export` of `profileDir` for
  # `host`, run by the packaged `repro` in the build sandbox with a private
  # HOME and state directory. The profile is copied to a writable directory
  # (the compile stages its configuration beside it). `--target` is not
  # passed: the evaluation is `evaluate`'s, in both modes.
  exportDerivation =
    {
      pkgs,
      repro,
      profileDir,
      host,
    }:
    let
      safeHost = builtins.replaceStrings [ " " "/" ] [ "-" "-" ] host;
    in
    pkgs.runCommand "repro-home-export-${safeHost}.json"
      {
        profile = profileDir;
        inherit host;
        nativeBuildInputs = [ repro ];
      }
      ''
        export HOME="$TMPDIR/home"
        export REPRO_HOME_STATE_DIR="$TMPDIR/state"
        unset REPRO_HOST
        mkdir -p "$HOME"
        cp -R "$profile" "$TMPDIR/profile"
        chmod -R u+w "$TMPDIR/profile"
        repro home export --profile-dir "$TMPDIR/profile" --host "$host" --format json > "$out"
      '';
in
{
  inherit
    evaluate
    refusalReason
    exportDerivation
    format
    knownSchemaVersions
    ;

  # reprobuild.lib.readIntent { host, system, snapshot ? null, profileDir ? null,
  #                             buildSystem ? <evaluator>, repro ? <pinned> }
  #
  # Snapshot mode when `snapshot` (a path to a committed export) is given,
  # IFD mode otherwise (`profileDir` required). Returns
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
              inherit profileDir host;
            })
          );
      reason = refusalReason document system;
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
