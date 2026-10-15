# The Reprobuild Nix helper library, exported as `reprobuild.lib`.
#
# Reprobuild is the source of truth and Nix a consumer (reprobuild-pm spec
# Gradual-Nix-To-Reprobuild-Migration.md §Principles P1, §The Nix helper
# library). Each consumer gets the same small set of readers instead of
# re-solving provisioning and parsing on its own:
#
#   readData           a plan-time data file, rows selected as the planner does
#   readIntent         a `repro home export` document (snapshot or IFD),
#                      evaluated for a target system and host
#   nixRealizationOf   canonical package -> nixpkgs attribute, from the pinned
#                      reprobuild-nix-packages contribution records
#   brewRealizationOf  canonical package -> Homebrew cask / formula token,
#                      from the pinned reprobuild-brew-packages contribution
#                      records (bridge records: Reprobuild never realizes them)
#   homeManagerFacts   a Home Manager configuration -> host facts, the Nix
#                      side of `repro home compare` (homeEquivalenceCheck
#                      runs the comparison as a check)
#
# User documentation: docs/user-guide/nix-helper-library.md.
#
# Arguments (supplied by flake.nix; a non-flake consumer can call this file
# directly):
#   catalogs  -- `[ { name; records; } ]`, published contribution-records
#                documents (`provisioning-contributions.json`). Every reader
#                reads every catalog and takes the records of its own kind
#                (Nix, Homebrew), so one list serves both.
#   pkgsFor   -- system -> nixpkgs package set, for the IFD derivation
#   reproFor  -- system -> the `repro` package that runs in it
{
  catalogs ? [ ],
  pkgsFor ? (system: throw "reprobuild.lib: no package set for ${system} (IFD mode needs pkgsFor)"),
  reproFor ? (
    system: throw "reprobuild.lib: no repro package for ${system} (IFD mode needs reproFor)"
  ),
}:
let
  predicate = import ./predicate.nix;
  platforms = import ./platforms.nix;
  data = import ./data.nix { inherit predicate platforms; };
  intent = import ./intent.nix { inherit predicate platforms; };
  realizations = import ./realizations.nix { inherit catalogs; };
  brew = import ./brew.nix { inherit catalogs; };
  hostFacts = import ./host-facts.nix {
    inherit realizations reproFor;
    brew = {
      lookupToken = brew.lookupBrewToken;
    };
  };
in
{
  inherit (data) readData;
  inherit (realizations) nixRealizationOf;
  readIntent = intent.mkReadIntent { inherit pkgsFor reproFor; };

  # The reverse of nixRealizationOf, for the equivalence report:
  # `{ pkgs, drv }` -> `{ found, name, attribute, packageName }` or
  # `{ found = false; reason; packageName; }` (nix/lib/realizations.nix).
  lookupNixPackageName = realizations.lookupCanonical;

  # Host facts (nix/lib/host-facts.nix; docs/user-guide/host-facts.md):
  # `homeManagerFacts` -- the Nix side of `repro home compare`, a derivation
  # writing the facts of a Home Manager configuration; `homeEquivalenceCheck`
  # -- a check derivation comparing it with `repro home facts` of a profile.
  inherit (hostFacts) homeManagerFacts homeEquivalenceCheck reprobuildFacts;

  # Non-throwing form of nixRealizationOf: `{ found, attribute, attrPath,
  # record, catalog }` or `{ found = false; reason; }`.
  lookupNixRealization = realizations.lookup;

  # Homebrew (nix/lib/brew.nix). `brewRealizationOf { name, system }` ->
  # null | `{ kind, token, tap }` is the Home Manager intent module's
  # `homebrew.realizationOf` hook; `lookupBrewRealization name` and
  # `lookupBrewToken { kind ? "cask", token }` are the non-throwing,
  # reporting forms (canonical name -> token, token -> canonical name);
  # `brewRecords` lists every record.
  inherit (brew)
    brewRealizationOf
    lookupBrewRealization
    lookupBrewToken
    brewRecords
    ;

  # Evaluate an already-read export document (an attribute set) for a target
  # system and host -- what readIntent does after reading. Throws when the
  # document cannot describe the system.
  evaluateExport =
    doc: system: host:
    intent.evaluate doc system host;

  # The derivation readIntent's IFD mode imports.
  inherit (intent) exportDerivation;

  # The built-in predicate grammar: `validate source` ->
  # `{ ok, ast }` / `{ ok = false, class, message }`; `holds facts source`.
  predicates = {
    inherit (predicate) validate holds evaluate;
    factsFor = platforms.factsFor;
  };
  targetSystems = platforms.systems;

  # Failure-as-value forms used by the library's own tests.
  internal = {
    inherit (data) readDataResult;
    inherit (intent) refusalReason;
  };
}
