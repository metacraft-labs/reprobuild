# Realization sources (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
# §Activity packages at rung 2,): where the Nix realization of a
# canonical package comes from when it is not the consumer's own nixpkgs.
#
# A source is an attribute set with exactly one of
#
#   { nixpkgs = <package set>; attribute ? null; }
#       a named nixpkgs-like package set (nixpkgs-unstable, say). The attribute
#       looked up in it is the one the pinned catalog's Nix contribution names
#       (`nixRealizationOf`), unless the consumer names `attribute`.
#   { packages = <package set>; attribute ? null; }
#       a flake's `packages.<system>`, which has no catalog record. The
#       attribute is the canonical name, unless the consumer names `attribute`.
#   { derivation = <derivation>; }
#       a derivation given directly, for a flake output that is not part of a
#       package set.
#
# `attribute` is a dotted path ("python3Packages.llm").
#
# A mapping is realization, not selection (P1): it never decides whether a
# host gets a package, only where it comes from. Its rules, refused by
# `problems` and thrown by the Home Manager module:
#
#   * a mapping for a name that is not a canonical package is refused: no
#     catalog contribution of any kind targets it and no host of the profile
#     selects it;
#   * a mapping for a canonical package that the profile selects on no host
#     is refused, so stale mappings cannot accumulate;
#   * a mapping that is not exactly one of the shapes above is refused.
#
# A package the profile selects with neither a mapping nor a catalog record
# is still `unmapped` (home-manager-mapping.nix), and fails the evaluation.
{ lookup }:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    foldl'
    isAttrs
    isString
    split
    tryEval
    ;

  kinds = [
    "nixpkgs"
    "packages"
    "derivation"
  ];
  allowedKeys = kinds ++ [ "attribute" ];

  isDerivation = x: isAttrs x && (x.type or null) == "derivation";

  # Why `source` is not a source, or null.
  shapeProblem =
    source:
    let
      given = filter (k: source ? ${k}) kinds;
      unknown = filter (k: !(elem k allowedKeys)) (attrNames source);
    in
    if !(isAttrs source) then
      "is not an attribute set (expected one of `nixpkgs = <package set>`, `packages = <package set>`, `derivation = <derivation>`)"
    else if unknown != [ ] then
      "has unknown key(s) ${concatStringsSep ", " (map (k: "`${k}`") unknown)} (known: ${concatStringsSep ", " allowedKeys})"
    else if builtins.length given != 1 then
      "must give exactly one of ${concatStringsSep ", " (map (k: "`${k}`") kinds)} (it gives ${toString (builtins.length given)})"
    else if (source ? derivation) && (source ? attribute) then
      "gives `attribute` with a `derivation`, which has no attribute to look up"
    else if (source ? derivation) && !(isDerivation source.derivation) then
      "`derivation` is not a derivation"
    else if (source ? attribute) && !(isString source.attribute && source.attribute != "") then
      "`attribute` is not a non-empty dotted path"
    else if
      ((source ? nixpkgs) && !(isAttrs source.nixpkgs)) || ((source ? packages) && !(isAttrs source.packages))
    then
      "names a package set that is not an attribute set"
    else
      null;

  attrPath = s: filter isString (split "\\." s);
  # The value at `path` of `set`, or null.
  at =
    set: path:
    foldl' (s: p: if s != null && isAttrs s then s.${p} or null else null) set path;

  # Resolve canonical package `name` through `source` to
  # `{ found = true; drv; label; }` or `{ found = false; reason; }`.
  # `label` says where it came from, for reports.
  resolve =
    name: source:
    let
      problem = shapeProblem source;
      kind = head' (filter (k: source ? ${k}) kinds);
      head' = l: builtins.head l;
      catalog = lookup name;
      attribute =
        if source ? attribute then
          source.attribute
        else if kind == "packages" then
          name
        else if catalog.found then
          catalog.attribute
        else
          null;
      set = source.${kind};
      drv = if attribute == null then null else at set (attrPath attribute);
    in
    if problem != null then
      {
        found = false;
        reason = "the realization source of `${name}` ${problem}";
      }
    else if kind == "derivation" then
      {
        found = true;
        drv = source.derivation;
        label = "the realization source's derivation";
      }
    else if attribute == null then
      {
        found = false;
        reason = "the realization source of `${name}` is a nixpkgs set, but no catalog contribution names an attribute for it (${catalog.reason}); name one with `attribute`";
      }
    else if !(isDerivation drv) then
      {
        found = false;
        reason = "the realization source of `${name}` has no derivation at `${attribute}` in its ${kind} set";
      }
    else
      {
        found = true;
        inherit drv;
        label = "the realization source's ${kind} set, `${attribute}`";
      };

  # The canonical package a derivation is, when it is what a source
  # resolves to (same store path): `null` when none, else
  # `{ found = true; name; attribute; origin; }` or `{ found = false; reason; }`
  # for a derivation two mappings resolve to.
  identify =
    { sources, drv }:
    let
      outOf = d: let r = tryEval d.outPath; in if r.success then r.value else null;
      mine = outOf drv;
      claims = filter (
        name:
        let
          r = resolve name sources.${name};
        in
        mine != null && r.found && outOf r.drv == mine
      ) (attrNames sources);
    in
    if claims == [ ] then
      null
    else if builtins.length claims > 1 then
      {
        found = false;
        reason = "the derivation is what the realization sources of ${concatStringsSep ", " (map (n: "`${n}`") claims)} resolve to; nothing selects one";
      }
    else
      let
        name = builtins.head claims;
        r = resolve name sources.${name};
      in
      {
        found = true;
        inherit name;
        attribute = r.label;
        origin = r.label;
      };

  # The refusals for `sources`: a list of messages, empty when none.
  # `catalogNames`: every canonical name a catalog contribution targets;
  # `selectedNames`: every name some host selects on some target.
  problems =
    {
      sources,
      catalogNames,
      selectedNames,
    }:
    concatMap' (
      name:
      let
        shape = shapeProblem sources.${name};
      in
      if shape != null then
        [ "realization source for `${name}` ${shape}" ]
      else if !(elem name catalogNames) && !(elem name selectedNames) then
        [ "realization source for `${name}`: `${name}` is not a canonical package (no catalog contribution targets it, and no host of the profile selects it)" ]
      else if !(elem name selectedNames) then
        [ "realization source for `${name}`: the profile selects `${name}` on no host, so the mapping is stale; remove it" ]
      else
        [ ]
    ) (attrNames sources);
  concatMap' = f: l: builtins.concatLists (map f l);
in
{
  inherit
    shapeProblem
    resolve
    identify
    problems
    ;
}
