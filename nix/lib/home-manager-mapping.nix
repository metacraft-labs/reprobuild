# Evaluated intent -> Home Manager option values, per category.
#
# The pure half of `reprobuild.homeManagerModules.intent`
# (nix/modules/home-manager-intent.nix): given an `evaluation` (what
# `reprobuild.lib.readIntent` returns, i.e. what `repro home export --target`
# reports) and the categories a host has opted into, compute the Home Manager
# values and the list of entries that could not be mapped. Kept apart from
# the module so it is testable without a Home Manager evaluation, and so the
# mapping rules sit in one place.
#
# Categories (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §The
# Nix helper library; opt-in individually, which is how a host sits on
# different adoption rungs for different concerns):
#
#   packages     evaluation.packages -> home.packages, through
#                nixRealizationOf (reprobuild-nix-packages) into `pkgs`
#   homebrew     pkg.homebrewCask / pkg.homebrewFormula resources, and
#                packages a Homebrew realization hook claims, -> token lists
#                for the host's Homebrew module (the module's default hook is
#                `reprobuild.lib.brewRealizationOf`, over the pinned
#                reprobuild-brew-packages catalog)
#   files        fs.userFile under ~ -> home.file
#   environment  env.userVariable -> home.sessionVariables,
#                env.userPath -> home.sessionPath
#
# Nothing is dropped. An entry of an ENABLED category that cannot be mapped
# faithfully lands in `unmapped` with the reason (a package no catalog
# realizes, a version pin the attribute does not satisfy, a file mode
# home.file cannot express, a command-generated file, …). An entry no
# category covers at all -- a config override, a systemd user unit, a
# managed block inside a file -- lands in `uncategorized`: Nix cannot apply
# it whichever categories are on. Entries of a DISABLED category are not
# reported: the host has left that concern to Reprobuild (or to other Nix
# code), which is the point of per-category opt-in. What the mapping does
# not RECOGNISE is never treated as somebody else's concern: a resource kind
# it does not know, or a field of a mapped kind it does not know, lands in
# `unmapped` whichever categories are enabled.
{ lib }:
let
  inherit (builtins)
    concatMap
    concatStringsSep
    filter
    hasAttr
    elem
    listToAttrs
    match
    substring
    stringLength
    ;

  fieldValue = r: name: r.fields.${name}.value or null;

  report = category: id: reason: { inherit category id reason; };

  homebrewKinds = {
    "pkg.homebrewCask" = "cask";
    "pkg.homebrewFormula" = "formula";
  };
  fileKinds = [ "fs.userFile" ];
  environmentKinds = [
    "env.userVariable"
    "env.userPath"
  ];

  # The fields each mapped kind may carry (its constructor's parameters in
  # repro_profile/resources.nim). A field outside the set is something the
  # mapping does not know how to honour -- a newer Reprobuild's addition,
  # say -- so the entry is reported unmapped rather than placed without it.
  mappedKindFields = {
    "fs.userFile" = [
      "hostFile"
      "content"
      "contentFromCommand"
      "mode"
      "executable"
      "cacheKey"
    ];
    "env.userVariable" = [
      "name"
      "value"
      "valueKind"
    ];
    "env.userPath" = [ "entries" ];
    "pkg.homebrewCask" = [
      "name"
      "version"
      "args"
    ];
    "pkg.homebrewFormula" = [
      "name"
      "version"
      "args"
    ];
  };

  # Home-scope kinds Reprobuild plans that no Home Manager category covers
  # (repro_home_intent `KnownResourceKinds`, repro_profile_compile
  # `resourceScope` = `rsHome`). They are reported `uncategorized`: Reprobuild
  # applies them, Nix does not. Any kind in neither this list nor a category
  # -- a kind added to Reprobuild after this library, or a system-scope kind
  # in a document `repro home export` did not produce (the planner refuses a
  # home profile that declares one) -- is NOT recognised, and is reported `unmapped` (an
  # error by default) whichever categories are enabled: the module cannot
  # tell whether it belongs to an enabled category, and treating it as
  # "not ours" would let a declaration silently never take effect
  # (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped).
  uncategorizedKinds = [
    "fs.managedBlock"
    "shell.integration"
    "windows.registryValue"
    "windows.registryValueHKCU"
    "windows.startup"
    "systemd.userUnit"
    "launchd.userAgent"
    "linux.dconfKey"
    "linux.kdeConfigKey"
    "vscode.extension"
  ];

  unknownFields =
    r: filter (f: !(elem f (mappedKindFields.${r.kind} or [ ]))) (builtins.attrNames (r.fields or { }));

  # The categories a resource kind belongs to (null: none).
  resourceCategory =
    kind:
    if hasAttr kind homebrewKinds then
      "homebrew"
    else if elem kind fileKinds then
      "files"
    else if elem kind environmentKinds then
      "environment"
    else
      null;

  # `~/rel` -> "rel"; anything else -> null.
  homeRelative =
    path:
    if path == "~" then
      null
    else if substring 0 2 path == "~/" && stringLength path > 2 then
      substring 2 (stringLength path - 2) path
    else
      null;

  mapUserFile =
    r:
    let
      hostFile = fieldValue r "hostFile";
      rel = if hostFile == null then null else homeRelative hostFile;
      mode = fieldValue r "mode";
      executable = fieldValue r "executable" == true;
      expectedMode = if executable then "0755" else "0644";
    in
    if r.fields ? contentFromCommand then
      {
        unmapped =
          report "files" r.address
            "the content is produced by a command at apply time (contentFromCommand), which a Home Manager evaluation cannot run";
      }
    else if rel == null then
      {
        unmapped =
          report "files" r.address
            "hostFile `${toString hostFile}` is not under ~/, and home.file only places files in the home directory";
      }
    else if mode != null && mode != expectedMode then
      {
        unmapped =
          report "files" r.address
            "mode ${mode} cannot be expressed by home.file (store-backed files are ${expectedMode} for executable = ${lib.boolToString executable})";
      }
    else
      {
        file = {
          name = rel;
          value = {
            text = fieldValue r "content";
            inherit executable;
          };
        };
      };

  mapEnvironment =
    r:
    if r.kind == "env.userVariable" then
      let
        valueKind = fieldValue r "valueKind";
      in
      if valueKind != null && valueKind != "string" then
        {
          unmapped =
            report "environment" r.address
              "valueKind `${valueKind}` (only plain string variables map to home.sessionVariables)";
        }
      else
        {
          variable = {
            name = fieldValue r "name";
            value = fieldValue r "value";
          };
        }
    else
      # `env.userPath`'s `entries` is a comma-separated list; blanks are
      # dropped (pipeline.nim `resourceFromEntry`).
      {
        path = filter (e: e != "") (
          map (e: lib.trim e) (filter builtins.isString (builtins.split "," (fieldValue r "entries")))
        );
      };

  mapHomebrew =
    r:
    let
      kind = homebrewKinds.${r.kind};
      version = fieldValue r "version";
      args = fieldValue r "args";
    in
    if (version != null && version != "") || (args != null && args != [ ]) then
      {
        unmapped =
          report "homebrew" r.address
            "a ${kind} with a version pin or install arguments; the Homebrew token lists carry tokens only";
      }
    else
      {
        brew = {
          inherit kind;
          token = fieldValue r "name";
        };
      };
in
{
  inherit resourceCategory uncategorizedKinds;

  # mapIntent { evaluation, pkgs, system, categories, lookupNixRealization,
  #             brewRealizationOf ? (_: null) }
  # `categories`: { packages, homebrew, files, environment } booleans.
  # `brewRealizationOf { name, system }` -> null | { kind = "cask" | "formula"; token; }
  mapIntent =
    {
      evaluation,
      pkgs,
      system,
      categories,
      lookupNixRealization,
      brewRealizationOf ? (_: null),
    }:
    let
      # --- packages (and packages Homebrew claims) -------------------------
      brewOf =
        p:
        if categories.homebrew then
          brewRealizationOf {
            inherit (p) name;
            inherit system;
          }
        else
          null;
      packageResults = map (
        p:
        let
          brew = brewOf p;
          r = lookupNixRealization p.name;
          drv = if r.found or false then lib.attrByPath r.attrPath null pkgs else null;
          id = "package:${p.name}";
        in
        if brew != null then
          { inherit brew; }
        else if !categories.packages then
          { }
        else if !(r.found or false) then
          { unmapped = report "packages" id r.reason; }
        else if drv == null then
          {
            unmapped =
              report "packages" id
                "the catalog names nixpkgs attribute `${r.attribute}`, which this package set does not have";
          }
        else if !(drv.meta.available or true) then
          {
            unmapped =
              report "packages" id
                "pkgs.${r.attribute} is not available on ${system} (meta.platforms / meta.broken)";
          }
        else if p.version != "" && (drv.version or null) != p.version then
          {
            unmapped =
              report "packages" id
                "pinned to version ${p.version}, but pkgs.${r.attribute} is ${
                  toString (drv.version or "unversioned")
                }";
          }
        else
          { package = drv; }
      ) evaluation.packages;

      # --- resources --------------------------------------------------------
      resourceResults = map (
        r:
        let
          category = resourceCategory r.kind;
        in
        if category == null && elem r.kind uncategorizedKinds then
          {
            uncategorized = report "none" r.address "resource kind `${r.kind}` has no Home Manager mapping";
          }
        else if category == null then
          {
            unmapped =
              report "unknown" r.address
                "resource kind `${r.kind}` is not one this library knows (a kind newer than this reprobuild flake, or not a home-scope kind); update the flake, or move the resource out of the home profile";
          }
        else if !categories.${category} then
          { }
        else if unknownFields r != [ ] then
          {
            unmapped =
              report category r.address
                "field(s) ${concatStringsSep ", " (unknownFields r)} of `${r.kind}` have no Home Manager mapping";
          }
        else if category == "files" then
          mapUserFile r
        else if category == "environment" then
          mapEnvironment r
        else
          mapHomebrew r
      ) (evaluation.resources or [ ]);

      overrideResults = map (o: {
        uncategorized =
          report "none" "config:${o.pkg}.${o.key}"
            "a config override has no Home Manager mapping";
      }) (evaluation.configOverrides or [ ]);

      all = packageResults ++ resourceResults ++ overrideResults;
      pick = attr: concatMap (x: if x ? ${attr} then [ x.${attr} ] else [ ]) all;
      brews = pick "brew";
    in
    {
      packages = pick "package";
      files = listToAttrs (pick "file");
      sessionVariables = listToAttrs (pick "variable");
      sessionPath = concatMap (x: x) (pick "path");
      casks = map (b: b.token) (filter (b: b.kind == "cask") brews);
      formulae = map (b: b.token) (filter (b: b.kind == "formula") brews);
      unmapped = pick "unmapped";
      uncategorized = pick "uncategorized";
    };
}
