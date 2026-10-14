# Evaluation tests of the Nix helper library (`reprobuild.lib`), run by the
# flake check `lib-tests` on every supported system.
#
# Everything here is decided at EVALUATION time: the check derivation exists
# only when every case passes, and evaluating it throws with the failures
# otherwise. That is what makes the darwin checks meaningful on a Linux
# evaluator (`nix flake check --all-systems` evaluates them without building
# them) and the Linux ones on macOS.
#
# The expectations are not restated here; they are Reprobuild's, read from
# the shared fixtures:
#
#   * tests/fixtures/predicates/cases.json -- the built-in predicate grammar
#     (also run by t_builtin_predicate_fixtures against predicate.nim);
#   * tests/fixtures/data-files/ -- readData row selection and refusals (also
#     run by t_data_file_row_selection_fixtures against the planner, and by
#     e2e_nix_reads_data_like_profile against `repro home export`);
#   * tests/fixtures/intent-exports/ -- readIntent's evaluation of a committed
#     export equals what `repro home export --target` reported for it
#     (evaluations.json, kept current by t_e2e_nix_reads_intent_like_export).
#
# The one synthetic input is the two-record catalog of the ambiguity case:
# reprobuild-nix-packages has no package with two Nix contributions, and
# "nothing selects one" must be refused, not resolved by order.
{
  lib,
  reprobuildLib,
  libFor,
  root,
}:
let
  inherit (builtins)
    attrNames
    concatMap
    elem
    filter
    fromJSON
    readDir
    readFile
    sort
    toJSON
    tryEval
    ;

  contains = lib.hasInfix;
  sortStrings = sort (a: b: a < b);
  dirs = path: filter (n: (readDir path).${n} == "directory") (attrNames (readDir path));

  # A failed case is `{ case; expected; got; }`; a passing one is dropped.
  expect =
    case: expected: got:
    if expected == got then [ ] else [ { inherit case expected got; } ];
  expectTrue = case: cond: expect case true cond;
  # Whether forcing `x` completely throws.
  fails = x: !(tryEval (builtins.deepSeq x x)).success;

  predicate = reprobuildLib.predicates;

  # --- the built-in predicate grammar --------------------------------------
  predicateCases = fromJSON (readFile (root + "/tests/fixtures/predicates/cases.json"));
  predicateTests =
    concatMap (
      e:
      let
        v = predicate.validate e.predicate;
        holdsOn =
          if v.ok then
            sortStrings (
              filter (s: predicate.evaluate (predicate.factsFor s e.host) v.ast) predicateCases.systems
            )
          else
            "refused: ${v.message}";
      in
      expect "predicate ${toJSON e.predicate} @ ${e.host}" (sortStrings e.holdsOn) holdsOn
    ) predicateCases.evaluations
    ++ concatMap (
      r:
      let
        v = predicate.validate r.predicate;
      in
      expect "predicate ${toJSON r.predicate} refused"
        {
          ok = false;
          class = r.error;
          identifier = r.identifier or null;
        }
        {
          inherit (v) ok;
          class = v.class or null;
          identifier = if r ? identifier then v.identifier or null else null;
        }
    ) predicateCases.rejections
    ++
      expect "the predicate fixtures cover every target system" (sortStrings reprobuildLib.targetSystems)
        (sortStrings predicateCases.systems);

  # --- readData ------------------------------------------------------------
  dataRoot = root + "/tests/fixtures/data-files";
  resourceRefusal = "does not read `[[resource]]` rows";
  hasResourceRows = dir: contains "[[resource]]" (readFile (dir + "/data.toml"));

  dataSelectionTests = concatMap (
    name:
    let
      dir = dataRoot + "/row-selection/${name}";
      c = fromJSON (readFile (dir + "/case.json"));
    in
    concatMap (
      e:
      let
        r = reprobuildLib.internal.readDataResult {
          path = dir + "/data.toml";
          inherit (e) system host;
          inherit (c) hosts;
        };
        case = "readData ${name}: ${e.host} @ ${e.system}";
      in
      if hasResourceRows dir then
        # Resource rows are refused, never ignored (data.nix header).
        expectTrue "${case} refuses the resource rows" (contains resourceRefusal (r.error or ""))
      else
        expect case e.packages (r.names or r.error)
    ) c.evaluations
  ) (dirs (dataRoot + "/row-selection"));

  dataRejectionTests = concatMap (
    name:
    let
      dir = dataRoot + "/row-rejection/${name}";
      c = fromJSON (readFile (dir + "/case.json"));
      r = reprobuildLib.internal.readDataResult {
        path = dir + "/data.toml";
        system = "x86_64-linux";
        host = "h";
      };
      message = r.error or "ACCEPTED";
      needles = if hasResourceRows dir then [ resourceRefusal ] else c.error;
    in
    concatMap (
      needle:
      expectTrue "readData ${name} refused with ${toJSON needle}: ${message}" (contains needle message)
    ) needles
  ) (dirs (dataRoot + "/row-rejection"));

  # The throwing entry point throws exactly when the value form fails.
  dataThrowTests =
    expectTrue "readData throws on a refused file" (
      fails (
        reprobuildLib.readData {
          path = dataRoot + "/row-rejection/unknown-row-key/data.toml";
          system = "x86_64-linux";
          host = "h";
        }
      )
    )
    ++
      expect "readData takes activities instead of hosts" [ "ghostty" "jq" "ripgrep" ]
        (reprobuildLib.readData {
          path = dataRoot + "/row-selection/activity-and-host-selection/data.toml";
          system = "aarch64-darwin";
          host = "m1";
          activities = [
            "desktop"
            "cli"
          ];
        }).names;

  # --- readIntent / evaluateExport -----------------------------------------
  intentRoot = root + "/tests/fixtures/intent-exports";
  evaluateOrRefuse =
    doc: system: host:
    if reprobuildLib.internal.refusalReason doc system != null then
      { refused = true; }
    else
      reprobuildLib.evaluateExport doc system host;

  intentCases = dirs intentRoot;
  intentTests = concatMap (
    name:
    let
      snapshot = intentRoot + "/${name}/export.json";
      doc = fromJSON (readFile snapshot);
      expected = fromJSON (readFile (intentRoot + "/${name}/evaluations.json"));
    in
    concatMap (
      host:
      concatMap (
        system:
        let
          want = expected.${host}.${system};
          viaReadIntent = fails (
            reprobuildLib.readIntent {
              inherit snapshot host system;
            }
          );
        in
        expect "intent ${name}: ${host} @ ${system}" want (evaluateOrRefuse doc system host)
        # readIntent refuses (throws) exactly where the evaluation is refused.
        ++ expect "readIntent ${name}: ${host} @ ${system} refuses iff Reprobuild refused" (
          want ? refused
        ) viaReadIntent
      ) (attrNames expected.${host})
    ) (attrNames expected)
  ) intentCases;

  neutral = fromJSON (readFile (intentRoot + "/neutral/export.json"));
  asSnapshot = name: doc: builtins.toFile "${name}.json" (toJSON doc);
  refusedSnapshot =
    name: doc:
    fails (
      reprobuildLib.readIntent {
        snapshot = asSnapshot name doc;
        host = "m1";
        system = "x86_64-linux";
      }
    );
  refusalTests =
    expectTrue "readIntent refuses an unknown schemaVersion" (
      refusedSnapshot "schema3" (neutral // { schemaVersion = 3; })
    )
    ++ expectTrue "readIntent refuses a document of another format" (
      refusedSnapshot "format" (neutral // { format = "something.else"; })
    )
    ++ expectTrue "readIntent refuses an intent that still names data files" (
      refusedSnapshot "datafiles" (
        neutral
        // {
          intent = neutral.intent // {
            dataFiles = [ "data/apps.toml" ];
          };
        }
      )
    )
    ++ expectTrue "readIntent refuses a platform whose entry is not `same`" (
      # Compiled on aarch64-linux; x86_64-linux could not be evaluated.
      refusedSnapshot "unevaluated" (
        neutral
        // {
          platforms = neutral.platforms // {
            "x86_64-linux" = "unevaluated";
          };
          provenance = neutral.provenance // {
            compile = neutral.provenance.compile // {
              target = "aarch64-linux";
            };
          };
        }
      )
    )
    ++ expectTrue "the refusal reason names the probe's diagnostic" (
      contains "nim check failed here" (
        toString (reprobuildLib.internal.refusalReason (
          neutral
          // {
            platforms = neutral.platforms // {
              "aarch64-darwin" = "unevaluated";
            };
            provenance = neutral.provenance // {
              compile = neutral.provenance.compile // {
                probe = {
                  "aarch64-darwin" = "nim check failed here";
                };
              };
            };
          }
        ) "aarch64-darwin")
      )
    )
    ++ expectTrue "the compiling platform is always described" (
      reprobuildLib.internal.refusalReason (
        neutral
        // {
          platforms = neutral.platforms // {
            "x86_64-linux" = "differs";
          };
        }
      ) "x86_64-linux" == null
    )
    ++ expectTrue "an unknown target system is refused" (
      reprobuildLib.internal.refusalReason neutral "riscv64-linux" != null
    )
    ++ expectTrue "readIntent without snapshot or profileDir is refused" (
      fails (
        reprobuildLib.readIntent {
          host = "m1";
          system = "x86_64-linux";
        }
      )
    );

  # --- nixRealizationOf -----------------------------------------------------
  realizationTests =
    expect "nixRealizationOf bash" "bash" (reprobuildLib.nixRealizationOf "bash")
    ++ expect "nixRealizationOf llvm (an attribute path)" "llvm.dev" (
      reprobuildLib.nixRealizationOf "llvm"
    )
    ++ expect "lookupNixRealization llvm's attrPath" [
      "llvm"
      "dev"
    ] (reprobuildLib.lookupNixRealization "llvm").attrPath
    ++
      expect "the bash record carries the catalog's pinned nixpkgs revision"
        "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"
        (reprobuildLib.lookupNixRealization "bash").record.nixpkgsRev
    ++ expectTrue "an unknown package is reported, not guessed" (
      let
        r = reprobuildLib.lookupNixRealization "ripgrep";
      in
      !r.found && contains "no Nix realization of `ripgrep`" r.reason
    )
    ++ expectTrue "nixRealizationOf throws for an unknown package" (
      fails (reprobuildLib.nixRealizationOf "ripgrep")
    )
    ++ (
      let
        record = file: line: attr: {
          targetPackage = "twice";
          contributor = "github:example/catalog-${file}";
          developInterface = false;
          location = {
            inherit file line;
          };
          nixProvisioning = [ { selector = "nixpkgs#${attr}"; } ];
        };
        catalog = name: records: {
          inherit name;
          records = builtins.toFile "${name}.json" (toJSON {
            format = "repro.provisioning-contributions";
            schemaVersion = 1;
            contributions = records;
          });
        };
        twoCatalogs = libFor [
          (catalog "a" [ (record "a.nim" 1 "hello") ])
          (catalog "b" [ (record "b.nim" 2 "hello2") ])
        ];
        r = twoCatalogs.lookupNixRealization "twice";
      in
      expectTrue "two contributions for one package are ambiguous" (
        !r.found && contains "2 Nix realizations" r.reason
      )
    );

  failures =
    predicateTests
    ++ dataSelectionTests
    ++ dataRejectionTests
    ++ dataThrowTests
    ++ intentTests
    ++ refusalTests
    ++ realizationTests;

  # Vacuity: the fixture trees were found and compared.
  counts = {
    predicateEvaluations = builtins.length predicateCases.evaluations;
    dataSelectionCases = builtins.length (dirs (dataRoot + "/row-selection"));
    dataRejectionCases = builtins.length (dirs (dataRoot + "/row-rejection"));
    intentCases = builtins.length intentCases;
  };
  vacuity =
    expectTrue "the fixture trees are populated" (
      counts.predicateEvaluations >= 30
      && counts.dataSelectionCases >= 6
      && counts.dataRejectionCases >= 10
      && counts.intentCases >= 2
    )
    ++ expectTrue "the intent fixtures include a refusal" (
      elem true (
        concatMap (
          name:
          let
            e = fromJSON (readFile (intentRoot + "/${name}/evaluations.json"));
          in
          concatMap (host: map (system: e.${host}.${system} ? refused) (attrNames e.${host})) (attrNames e)
        ) intentCases
      )
    );
in
{
  failures = failures ++ vacuity;
  inherit counts;
}
