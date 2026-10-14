# `reprobuild.lib.nixRealizationOf` -- canonical package name to the nixpkgs
# attribute a provisioning catalog's Nix contribution names.
#
# Profiles and data files name canonical Reprobuild packages only; how a
# package is realized in one ecosystem is a provisioning contribution, stated
# once for every user (reprobuild-pm spec Provisioning-Contributions.md;
# Gradual-Nix-To-Reprobuild-Migration.md §The Nix helper library: "the only
# place such a mapping lives"). The Nix contributions live in
# `reprobuild-nix-packages`, as `provisioningFor` blocks in its `repro.nim`.
# A Nix evaluation cannot run that recipe, so the catalog publishes its
# records as data (`provisioning-contributions.json`, rendered from the
# interface artifact by `repro_interface_artifacts/contribution_records` and
# checked for staleness by the catalog's own tests), and this file reads that
# document from the revision the reprobuild flake pins
# (`reprobuild-nix-packages-src`).
#
# Resolution, for one canonical name (Provisioning-Contributions.md
# §Resolution, the parts a data reader can apply):
#
#   * the contributions whose `targetPackage` is the name and that carry a
#     Nix realization;
#   * none -> not realizable from this catalog (reported, never guessed);
#   * a `developInterface` contribution -> refused (forbidden in a published
#     catalog);
#   * more than one -> ambiguous (no lock or policy selects one here, and
#     import order is never a selection rule);
#   * the one realization's `selector` must be `nixpkgs#<attribute path>`
#     (a realization from an expression file or another flake names no
#     attribute of the consumer's nixpkgs).
#
# What is NOT applied: the record's `nixpkgsRev` / `nixpkgsNarHash`. The
# attribute is looked up in the consumer's own nixpkgs (a Home Manager
# configuration's `pkgs`); the pinned revision stays available in `record`
# for a consumer that wants to compare or fetch it.
{ catalogs }:
let
  inherit (builtins)
    concatMap
    filter
    fromJSON
    length
    head
    readFile
    match
    concatStringsSep
    ;

  recordsFormat = "repro.provisioning-contributions";
  knownSchemaVersions = [ 1 ];

  # Every Nix realization of every catalog, as `{ catalog, contribution,
  # realization }`. A catalog is `{ name, records }`, `records` a path to a
  # published contribution-records document.
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
        map (realization: { inherit catalog contribution realization; }) (
          contribution.nixProvisioning or [ ]
        )
      ) doc.contributions;

  realizations = concatMap loadCatalog catalogs;

  where =
    r:
    "${r.catalog.name} ${r.contribution.location.file or "?"}:${
      toString (r.contribution.location.line or 0)
    }";

  # Resolve `name`. Returns `{ found = true; attribute; attrPath; record;
  # catalog; }` or `{ found = false; reason; }` -- the form the Home Manager
  # module uses to report an unmapped package instead of failing on it.
  lookup =
    name:
    let
      matches = filter (r: r.contribution.targetPackage == name) realizations;
      only = head matches;
      selector = only.realization.selector or "";
      attr = match "nixpkgs#(.+)" selector;
    in
    if matches == [ ] then
      {
        found = false;
        reason = "no Nix realization of `${name}` in ${concatStringsSep ", " (map (c: c.name) catalogs)}";
      }
    else if length matches > 1 then
      {
        found = false;
        reason = "`${name}` has ${toString (length matches)} Nix realizations (${concatStringsSep "; " (map where matches)}) and nothing selects one";
      }
    else if only.contribution.developInterface or false then
      {
        found = false;
        reason = "`${name}`'s Nix contribution (${where only}) binds a develop interface, which a published catalog may not";
      }
    else if attr == null then
      {
        found = false;
        reason = "`${name}`'s Nix realization (${where only}) is `${selector}`, not a `nixpkgs#<attribute>` selector";
      }
    else
      {
        found = true;
        attribute = head attr;
        attrPath = builtins.filter builtins.isString (builtins.split "\\." (head attr));
        record = only.realization;
        catalog = only.catalog.name;
      };
in
{
  inherit lookup;

  # reprobuild.lib.nixRealizationOf name -> "attribute.path"
  # Throws (with the reason) for a name no catalog realizes unambiguously.
  nixRealizationOf =
    name:
    let
      r = lookup name;
    in
    if r.found then r.attribute else throw "reprobuild.lib.nixRealizationOf: ${r.reason}";

  # The canonical names every catalog realizes, for reports.
  realizedNames = builtins.attrNames (
    builtins.listToAttrs (
      map (r: {
        name = r.contribution.targetPackage;
        value = true;
      }) realizations
    )
  );
}
