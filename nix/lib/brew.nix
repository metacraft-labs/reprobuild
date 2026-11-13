# `reprobuild.lib.brewRealizationOf` and its relatives -- canonical package
# names to Homebrew tokens and back, from a Homebrew contribution catalog.
#
# While Home Manager still installs macOS applications through Homebrew, a
# Nix consumer needs to know which Homebrew token realizes a canonical
# package (to install it), and the equivalence report needs the reverse (to
# name what a Brewfile installs by canonical package). That mapping is a
# provisioning contribution like any other, stated once in
# `reprobuild-brew-packages` as `provisioningFor` blocks with `brewCask` /
# `brewFormula` records, and published as data in its
# `provisioning-contributions.json` (reprobuild-pm spec
# Provisioning-Contributions.md §"Homebrew bridge records";
# Gradual-Nix-To-Reprobuild-Migration.md §The Nix helper library). This file
# reads the same published documents `realizations.nix` reads and looks only
# at their `homebrewProvisioning` records. Reprobuild itself never realizes a
# Homebrew record; these readers are the records' only consumer.
#
# Resolution applies what a data reader can of §Resolution, as
# `realizations.nix` does for Nix records:
#
#   * by canonical name: no Homebrew record -> not claimed (reported, never
#     guessed); more than one -> ambiguous (nothing selects one, and import
#     order never does); a `developInterface` contribution -> refused;
#   * by token: the records of that kind and token; none -> unknown token
#     (reported, never guessed: no fuzzy match, no default package); records
#     for more than one canonical package -> ambiguous.
#
# Platforms: Homebrew casks are macOS-only, so a cask claims a package only
# for a darwin system; formulae are claimed on darwin and Linux (Homebrew
# runs on both).
{ catalogs }:
let
  inherit (builtins)
    concatMap
    concatStringsSep
    filter
    fromJSON
    head
    length
    readFile
    ;

  recordsFormat = "repro.provisioning-contributions";
  knownSchemaVersions = [ 1 ];
  knownKinds = [
    "cask"
    "formula"
  ];

  # Every Homebrew record of every catalog, as `{ catalog, contribution,
  # record }`. The document checks are realizations.nix's: a document this
  # library cannot read is refused, never skipped.
  loadCatalog =
    catalog:
    let
      doc = fromJSON (readFile catalog.records);
    in
    if (doc.format or null) != recordsFormat then
      throw "reprobuild: ${catalog.name}: ${toString catalog.records} is not a contribution-records document (format ${
        builtins.toJSON (doc.format or null)
      })"
    else if !(builtins.elem (doc.schemaVersion or null) knownSchemaVersions) then
      throw "reprobuild: ${catalog.name}: contribution-records schemaVersion ${
        builtins.toJSON (doc.schemaVersion or null)
      } is not one this library reads (${builtins.toJSON knownSchemaVersions})"
    else
      concatMap (
        contribution:
        map (
          record:
          if builtins.elem (record.kind or null) knownKinds then
            { inherit catalog contribution record; }
          else
            throw "reprobuild: ${catalog.name}: `${contribution.targetPackage}` has a Homebrew record of kind ${
              builtins.toJSON (record.kind or null)
            } (known: cask, formula)"
        ) (contribution.homebrewProvisioning or [ ])
      ) doc.contributions;

  records = concatMap loadCatalog catalogs;

  catalogNames = concatStringsSep ", " (map (c: c.name) catalogs);

  where =
    r:
    "${r.catalog.name} ${r.record.location.file or r.contribution.location.file or "?"}:${
      toString (r.record.location.line or r.contribution.location.line or 0)
    }";

  describe = r: "${r.record.kind} `${r.record.token}`";

  isDarwin = system: builtins.match ".*-darwin" system != null;
  isLinux = system: builtins.match ".*-linux" system != null;
  # Whether Homebrew can install a record of `kind` on `system`.
  appliesOn =
    kind: system: if kind == "cask" then isDarwin system else isDarwin system || isLinux system;

  found = r: {
    found = true;
    inherit (r.record) kind token;
    tap = r.record.tap or "";
    name = r.contribution.targetPackage;
    record = r.record;
    catalog = r.catalog.name;
  };

  # Canonical name -> its one Homebrew record, or `{ found = false; reason; }`.
  lookup =
    name:
    let
      matches = filter (r: r.contribution.targetPackage == name) records;
      only = head matches;
    in
    if matches == [ ] then
      {
        found = false;
        reason = "no Homebrew record claims `${name}` in ${catalogNames}";
      }
    else if length matches > 1 then
      {
        found = false;
        reason = "`${name}` has ${toString (length matches)} Homebrew records (${
          concatStringsSep "; " (map (r: "${describe r} at ${where r}") matches)
        }) and nothing selects one";
      }
    else if only.contribution.developInterface or false then
      {
        found = false;
        reason = "`${name}`'s Homebrew contribution (${where only}) binds a develop interface, which a published catalog may not";
      }
    else
      found only;

  # `{ kind ? "cask", token }` -> the canonical package it installs, or
  # `{ found = false; reason; }`.
  lookupToken =
    {
      kind ? "cask",
      token,
    }:
    let
      matches = filter (r: r.record.kind == kind && r.record.token == token) records;
      names = builtins.attrNames (
        builtins.listToAttrs (
          map (r: {
            name = r.contribution.targetPackage;
            value = true;
          }) matches
        )
      );
      only = head matches;
    in
    if !(builtins.elem kind knownKinds) then
      {
        found = false;
        reason = "`${kind}` is not a Homebrew record kind (known: cask, formula)";
      }
    else if matches == [ ] then
      {
        found = false;
        reason = "no canonical package in ${catalogNames} is installed by Homebrew ${kind} `${token}`";
      }
    else if length names > 1 then
      {
        found = false;
        reason = "Homebrew ${kind} `${token}` is claimed by ${toString (length names)} canonical packages (${concatStringsSep ", " names}: ${
          concatStringsSep "; " (map where matches)
        })";
      }
    else if only.contribution.developInterface or false then
      {
        found = false;
        reason = "Homebrew ${kind} `${token}`'s contribution (${where only}) binds a develop interface, which a published catalog may not";
      }
    else
      found only;
in
{
  lookupBrewRealization = lookup;
  lookupBrewToken = lookupToken;

  # reprobuild.lib.brewRealizationOf { name, system } -> null | { kind; token; tap; }
  #
  # The Home Manager intent module's `homebrew.realizationOf` hook (and its
  # default): null when no Homebrew record claims `name`, or when the record
  # cannot be installed on `system` (a cask off macOS) -- the package then
  # stays with the `packages` category. A record the catalog states
  # ambiguously or with a develop interface is a catalog defect and throws,
  # rather than quietly leaving the package to another category.
  brewRealizationOf =
    { name, system }:
    let
      r = lookup name;
      claimed = builtins.any (x: x.contribution.targetPackage == name) records;
    in
    if r.found then
      (
        if appliesOn r.kind system then
          {
            inherit (r) kind token tap;
          }
        else
          null
      )
    else if claimed then
      throw "reprobuild.lib.brewRealizationOf: ${r.reason}"
    else
      null;

  # Every Homebrew record, `{ name, kind, token, tap, catalog }`, in catalog
  # order -- for reports.
  brewRecords = map (r: {
    name = r.contribution.targetPackage;
    inherit (r.record) kind token;
    tap = r.record.tap or "";
    catalog = r.catalog.name;
  }) records;
}
