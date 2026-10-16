# The flake check `lib-intent-ifd`: `reprobuild.lib.readIntent` in IFD mode.
#
# For each fixture profile under tests/fixtures/intent-exports/, readIntent
# without a snapshot builds `exportDerivation` -- the packaged `repro home
# export` running in the Nix build sandbox, no wrapper, no HOME, no checkout --
# for `buildSystem` and imports the document. The check asserts, for this
# check's target `system`:
#
#   * the sandboxed export says what the committed snapshot says (the fields
#     `repro home export --check` compares: format, schemaVersion, intent,
#     platforms; selection differs only by the host it was made for, and is
#     recomputed per host anyway);
#   * its evaluation equals the snapshot-mode evaluation for every fixture
#     host the profile declares (`m1`, `home-pc`); `server`, which its
#     `hosts:` registry does not declare, is refused (spec Open question 6).
#     In IFD mode that refusal is the export derivation failing to build
#     (`repro home export --host server` exits 1 naming the declared hosts),
#     which an evaluation cannot catch, so the check asserts it in snapshot
#     mode, where the same rule throws;
#   * the compile-time-dependent profile is refused exactly where the build
#     system's compile does not describe the target: the darwin targets when
#     a non-darwin system exported it, the others when darwin did.
#
# The IFD derivation is built for `buildSystem` (the evaluator, when the
# evaluation is impure; this check's own system otherwise), never for the
# target -- which is how a Linux evaluator describes a darwin host.
{
  pkgs,
  system,
  buildSystem,
  reprobuildLib,
  root,
}:
let
  inherit (builtins) fromJSON readFile;
  fixtures = root + "/tests/fixtures/intent-exports";
  hosts = [
    "m1"
    "home-pc"
  ];
  isDarwin = s: builtins.match ".*-darwin" s != null;
  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;
  comparedFields = doc: {
    inherit (doc)
      format
      schemaVersion
      intent
      platforms
      ;
  };

  ifd =
    name: host:
    reprobuildLib.readIntent {
      profileDir = fixtures + "/${name}/profile";
      inherit host system buildSystem;
    };
  snapshotOf = name: host: {
    snapshot = fixtures + "/${name}/export.json";
    inherit host system;
  };

  # The neutral export describes every target, so its document is readable
  # for any `system`.
  neutral = (ifd "neutral" "m1").document;
  neutralSnapshot = fromJSON (readFile (fixtures + "/neutral/export.json"));

  results = {
    ifd-mode = (ifd "neutral" "home-pc").mode == "ifd";
    built-on-the-evaluator = neutral.provenance.compile.target == buildSystem;
    neutral-matches-snapshot = comparedFields neutral == comparedFields neutralSnapshot;
    neutral-evaluations = builtins.all (
      host:
      (ifd "neutral" host).evaluation == (reprobuildLib.readIntent (snapshotOf "neutral" host)).evaluation
    ) hosts;
    undeclared-host-refused = fails (reprobuildLib.readIntent (snapshotOf "neutral" "server"));
    compile-time-refusal =
      let
        refused = fails (ifd "compile-time" "m1");
      in
      refused == (isDarwin system != isDarwin buildSystem);
  };
  failed = builtins.attrNames (pkgs.lib.filterAttrs (_: ok: !ok) results);
in
if failed == [ ] then
  pkgs.writeText "reprobuild-lib-intent-ifd" (builtins.toJSON (results // { inherit buildSystem; }))
else
  throw "reprobuild lib-intent-ifd (${system}, built on ${buildSystem}): failed: ${builtins.concatStringsSep ", " failed}"
