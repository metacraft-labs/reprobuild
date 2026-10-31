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
      if e.undeclaredHost or false then
        # A host the case's hosts: registry does not declare is refused, as
        # the planner refuses it (hosts.nix; spec Open question 6).
        expectTrue "${case} refuses the undeclared host" (
          contains "host `${e.host}` is not declared in the profile's hosts: registry" (r.error or "")
        )
      else if hasResourceRows dir then
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
  # The order `repro home export` refuses in: an undeclared host first (the
  # export itself fails), then a target the document does not describe.
  evaluateOrRefuse =
    doc: system: host:
    if reprobuildLib.internal.hostRefusalReason doc host != null then
      { undeclaredHost = true; }
    else if reprobuildLib.internal.refusalReason doc system != null then
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
          want ? refused || want ? undeclaredHost
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
      refusedSnapshot "schema6" (neutral // { schemaVersion = 6; })
    )
    # ReproOS add-on mode: a schema-4 document cannot say a host is an
    # add-on host, so its add-on hosts would read as managed here in full.
    ++ expectTrue "readIntent refuses the previous schemaVersion (4)" (
      refusedSnapshot "schema4" (neutral // { schemaVersion = 4; })
    )
    # GM10: a schema-3 document cannot say a host's system is managed
    # elsewhere, so a reader that acts on the attribute must not take its
    # silence for "managed here".
    ++ expectTrue "readIntent refuses the previous schemaVersion (3)" (
      refusedSnapshot "schema3" (neutral // { schemaVersion = 3; })
    )
    # GM9: a schema-2 reader would apply activity-scoped resources on every
    # host, so a document is read by the version it declares only.
    ++ expectTrue "readIntent refuses the previous schemaVersion (2)" (
      refusedSnapshot "schema2" (neutral // { schemaVersion = 2; })
    )
    ++ expectTrue "readIntent refuses a resource of an undeclared activity" (
      refusedSnapshot "undeclared-activity" (
        neutral
        // {
          intent = neutral.intent // {
            resources = neutral.intent.resources ++ [
              {
                kind = "fs.userFile";
                address = "gm9-orphan";
                fields = { };
                dependsOn = [ ];
                guard = null;
                activity = "gm9_no_such_activity";
              }
            ];
          };
        }
      )
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
    ++ expect "nixRealizationOf pwsh" "powershell" (reprobuildLib.nixRealizationOf "pwsh")
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

  # --- brewRealizationOf (GM5b) ---------------------------------------------
  # The real pinned catalog (reprobuild-brew-packages) for the mappings a
  # host relies on, and synthetic catalogs for the refusals the real one must
  # never exhibit (an ambiguous name or token, a develop interface, an
  # unknown record kind).
  brewTests =
    let
      mkRecord =
        {
          target,
          kind ? "cask",
          token,
          file ? "repro.nim",
          line ? 1,
          develop ? false,
        }:
        {
          targetPackage = target;
          contributor = "github:example/brew-${file}";
          developInterface = develop;
          location = {
            inherit file line;
          };
          homebrewProvisioning = [
            {
              inherit kind token;
              tap = "";
              location = {
                inherit file;
                line = line + 1;
              };
            }
          ];
        };
      catalog = name: records: {
        inherit name;
        records = builtins.toFile "${name}.json" (toJSON {
          format = "repro.provisioning-contributions";
          schemaVersion = 1;
          contributions = records;
        });
      };
      synthetic = libFor [
        (catalog "a" [
          (mkRecord {
            target = "twice";
            token = "twice-a";
            file = "a.nim";
          })
          (mkRecord {
            target = "shared-a";
            token = "shared";
            file = "a.nim";
            line = 5;
          })
          (mkRecord {
            target = "devpkg";
            token = "devpkg";
            develop = true;
          })
          (mkRecord {
            target = "cli";
            kind = "formula";
            token = "cli-tool";
          })
        ])
        (catalog "b" [
          (mkRecord {
            target = "twice";
            token = "twice-b";
            file = "b.nim";
            line = 2;
          })
          (mkRecord {
            target = "shared-b";
            token = "shared";
            file = "b.nim";
            line = 7;
          })
        ])
      ];
      badKind = libFor [
        (catalog "bad" [
          (mkRecord {
            target = "x";
            kind = "tap";
            token = "x";
          })
        ])
      ];
      darwin = "aarch64-darwin";
      linux = "x86_64-linux";
    in
    # The real catalog: the application set and the casks a Brewfile names.
    expect "brewRealizationOf vscode on aarch64-darwin" {
      kind = "cask";
      token = "visual-studio-code";
      tap = "";
    } (reprobuildLib.brewRealizationOf {
      name = "vscode";
      system = darwin;
    })
    ++ expect "brewRealizationOf jdk on x86_64-darwin is temurin@21" "temurin@21"
      (reprobuildLib.brewRealizationOf {
        name = "jdk";
        system = "x86_64-darwin";
      }).token
    ++ expect "a cask claims nothing on Linux" null (
      reprobuildLib.brewRealizationOf {
        name = "vscode";
        system = linux;
      }
    )
    ++ expect "an unclaimed package is not claimed" null (
      reprobuildLib.brewRealizationOf {
        name = "bash";
        system = darwin;
      }
    )
    ++ expectTrue "an unclaimed package is reported, not guessed" (
      let
        r = reprobuildLib.lookupBrewRealization "bash";
      in
      !r.found && contains "no Homebrew record claims `bash`" r.reason
    )
    ++ expect "lookupBrewToken visual-studio-code" "vscode"
      (reprobuildLib.lookupBrewToken { token = "visual-studio-code"; }).name
    ++ expect "lookupBrewToken codex-app is the desktop app" "codex-desktop"
      (reprobuildLib.lookupBrewToken { token = "codex-app"; }).name
    ++ expectTrue "an unknown token maps to nothing and is reported" (
      let
        r = reprobuildLib.lookupBrewToken { token = "gm5b-no-such-cask"; };
      in
      !r.found
      && !(r ? name)
      && contains "no canonical package in reprobuild-nix-packages, reprobuild-brew-packages is installed by Homebrew cask `gm5b-no-such-cask`" r.reason
    )
    ++ expectTrue "a cask token is not found as a formula" (
      !(reprobuildLib.lookupBrewToken {
        kind = "formula";
        token = "visual-studio-code";
      }).found
    )
    ++ expectTrue "the real catalog maps each name and each token once" (
      let
        recs = reprobuildLib.brewRecords;
        uniq = xs: builtins.length (builtins.attrNames (lib.genAttrs xs (_: true))) == builtins.length xs;
      in
      builtins.length recs >= 30
      && uniq (map (r: r.name) recs)
      && uniq (map (r: "${r.kind}:${r.token}") recs)
    )
    ++ expectTrue "the Nix catalog contributes no Homebrew record" (
      builtins.all (r: r.catalog == "reprobuild-brew-packages") reprobuildLib.brewRecords
    )
    # Synthetic catalogs: the refusals.
    ++ expectTrue "a formula claims on Linux and darwin" (
      (synthetic.brewRealizationOf {
        name = "cli";
        system = linux;
      }) == {
        kind = "formula";
        token = "cli-tool";
        tap = "";
      }
      && (synthetic.brewRealizationOf {
        name = "cli";
        system = darwin;
      }) != null
    )
    ++ expectTrue "two Homebrew records for one package are ambiguous" (
      let
        r = synthetic.lookupBrewRealization "twice";
      in
      !r.found && contains "2 Homebrew records" r.reason && contains "a a.nim:2" r.reason
    )
    ++ expectTrue "brewRealizationOf throws on an ambiguous package" (
      fails (
        synthetic.brewRealizationOf {
          name = "twice";
          system = darwin;
        }
      )
    )
    ++ expectTrue "a token two packages claim is ambiguous, not guessed" (
      let
        r = synthetic.lookupBrewToken { token = "shared"; };
      in
      !r.found && contains "claimed by 2 canonical packages (shared-a, shared-b" r.reason
    )
    ++ expectTrue "a develop-interface contribution is refused" (
      !(synthetic.lookupBrewRealization "devpkg").found
      && !(synthetic.lookupBrewToken { token = "devpkg"; }).found
      && fails (
        synthetic.brewRealizationOf {
          name = "devpkg";
          system = darwin;
        }
      )
    )
    ++ expectTrue "an unknown record kind is refused, not skipped" (fails badKind.brewRecords)
    ++ expectTrue "an unknown lookup kind is reported" (
      contains "not a Homebrew record kind" (
        synthetic.lookupBrewToken {
          kind = "tap";
          token = "x";
        }
      ).reason
    );

  # The profile's commands (Gradual-Nix-To-Reprobuild-Migration.md
  # §Concern-scoped apply): `profileBinPath` resolves the location the export
  # publishes for a host that leaves `environment` to Nix while Reprobuild
  # writes launchers; an export without that row is refused for such a host
  # rather than leaving the commands off PATH unnoticed.
  concernsDoc = fromJSON (readFile (intentRoot + "/concerns/export.json"));
  serverOn = system: reprobuildLib.evaluateExport concernsDoc system "server";
  profileBinTests =
    expectTrue "profileBinPath: macOS, under the home directory" (
      reprobuildLib.profileBinPath {
        evaluation = serverOn "aarch64-darwin";
        homeDirectory = "/Users/u";
      } == "/Users/u/Library/Application Support/repro/home/current/bin"
    )
    ++ expectTrue "profileBinPath: Linux, under the XDG state directory (default and moved)" (
      reprobuildLib.profileBinPath {
        evaluation = serverOn "x86_64-linux";
        homeDirectory = "/home/u";
      } == "/home/u/.local/state/repro/home/current/bin"
      && reprobuildLib.profileBinPath {
        evaluation = serverOn "x86_64-linux";
        homeDirectory = "/home/u";
        xdgStateHome = "/var/state/u";
      } == "/var/state/u/repro/home/current/bin"
    )
    ++ expectTrue "profileBinPath: a Windows location is refused" (
      fails (
        reprobuildLib.profileBinPath {
          evaluation = serverOn "x86_64-windows";
          homeDirectory = "C:/Users/u";
        }
      )
    )
    ++ expectTrue "profileBinPath: null where Reprobuild owns the environment or nothing is declared" (
      reprobuildLib.profileBinPath {
        evaluation = reprobuildLib.evaluateExport concernsDoc "aarch64-darwin" "m1";
        homeDirectory = "/Users/u";
      } == null
      && reprobuildLib.profileBinPath {
        evaluation = reprobuildLib.evaluateExport concernsDoc "aarch64-darwin" "home-pc";
        homeDirectory = "/Users/u";
      } == null
    )
    ++ expectTrue "an export without concerns.profileBin is refused for a host that needs it" (
      fails (
        (reprobuildLib.evaluateExport (
          concernsDoc
          // {
            concerns = removeAttrs concernsDoc.concerns [ "profileBin" ];
          }
        ) "aarch64-darwin" "server").profileBin
      )
      # ...and only for such a host.
      && !(fails (
        reprobuildLib.evaluateExport (
          concernsDoc
          // {
            concerns = removeAttrs concernsDoc.concerns [ "profileBin" ];
          }
        ) "aarch64-darwin" "m1"
      ))
    );

  # GM10: `hostSystemManagement` answers what the evaluation's `system`
  # says, for every declared host of every intent fixture (whose evaluations
  # are Reprobuild's own, `evaluations.json`), and refuses what readIntent
  # refuses. The neutral fixture declares m1's system managed elsewhere
  # (`example-org/infra`), home-pc's managed here and rpi and validator
  # add-on hosts, so every answer occurs.
  systemManagementTests =
    concatMap (
      name:
      let
        snapshot = intentRoot + "/${name}/export.json";
        expected = fromJSON (readFile (intentRoot + "/${name}/evaluations.json"));
      in
      concatMap (
        host:
        let
          evaluated = filter (e: e ? system) (map (s: expected.${host}.${s}) (attrNames expected.${host}));
          undeclared = elem true (map (s: expected.${host}.${s} ? undeclaredHost) (attrNames expected.${host}));
        in
        if undeclared then
          expectTrue "hostSystemManagement ${name}: refuses undeclared host ${host}" (
            fails (reprobuildLib.hostSystemManagement { inherit snapshot host; })
          )
        else if evaluated == [ ] then
          [ ]
        else
          expect "hostSystemManagement ${name}: ${host}" ({ inherit host; } // (builtins.head evaluated).system) (
            reprobuildLib.hostSystemManagement { inherit snapshot host; }
          )
      ) (attrNames expected)
    ) intentCases
    ++ expect "hostSystemManagement: the neutral fixture's m1 is managed elsewhere" {
      host = "m1";
      managed = "elsewhere";
      managedBy = "example-org/infra";
      mode = "managedElsewhere";
      activities = [ ];
    } (reprobuildLib.hostSystemManagement { document = neutral; host = "m1"; })
    ++ expect "hostSystemManagement: the neutral fixture's home-pc is managed here, in full" {
      host = "home-pc";
      managed = "here";
      managedBy = null;
      mode = "full";
      activities = [ "default" ];
    } (reprobuildLib.hostSystemManagement { document = neutral; host = "home-pc"; })
    # ReproOS add-on mode: an add-on host is managed "here", but its mode
    # is `addOn` -- the base is its distribution's, and a system switch that
    # takes "here" to mean "the whole system" must not run on it.
    ++ expect "hostSystemManagement: the neutral fixture's rpi is an add-on host (default only)" {
      host = "rpi";
      managed = "here";
      managedBy = null;
      mode = "addOn";
      activities = [ "default" ];
    } (reprobuildLib.hostSystemManagement { document = neutral; host = "rpi"; })
    ++ expect "hostSystemManagement: the neutral fixture's validator selects system activities" {
      host = "validator";
      managed = "here";
      managedBy = null;
      mode = "addOn";
      activities = [
        "default"
        "web"
        "backup"
      ];
    } (reprobuildLib.hostSystemManagement { document = neutral; host = "validator"; })
    ++ expect "hostSystemManagement: the neutral fixture's pc-full selects system activities while fully managed" {
      host = "pc-full";
      managed = "here";
      managedBy = null;
      mode = "full";
      activities = [
        "default"
        "web"
      ];
    } (reprobuildLib.hostSystemManagement { document = neutral; host = "pc-full"; })
    # A schema-4 document cannot say `addOn`: its add-on hosts would read as
    # managed here in full. Refused, by readIntent and hostSystemManagement.
    ++ expectTrue "hostSystemManagement refuses the previous schemaVersion (4)" (
      fails (reprobuildLib.hostSystemManagement {
        document = neutral // { schemaVersion = 4; };
        host = "home-pc";
      })
    )
    ++ expectTrue "hostSystemManagement refuses a schema-4 document's systemManagedElsewhere shape" (
      fails (reprobuildLib.hostSystemManagement {
        document = (removeAttrs neutral [ "schemaVersion" ]) // {
          schemaVersion = 4;
          intent = (removeAttrs neutral.intent [ "hostSystems" ]) // {
            systemManagedElsewhere = {
              "m1" = {
                managedBy = "example-org/infra";
              };
            };
          };
        };
        host = "m1";
      })
    )
  ++ concatMap (
      bad:
      expectTrue "hostSystemManagement refuses a malformed entry: ${bad.why}" (
        fails (reprobuildLib.hostSystemManagement {
          document = neutral // {
            intent = neutral.intent // {
              hostSystems = neutral.intent.hostSystems // {
                "home-pc" = bad.entry;
              };
            };
          };
          host = "m1";
        })
      )
    ) [
      {
        why = "a bare string";
        entry = "example-org/infra";
      }
      {
        why = "no mode";
        entry = {
          managedBy = null;
          activities = [ ];
        };
      }
      {
        why = "an unknown mode";
        entry = {
          mode = "here";
          managedBy = null;
          activities = [ ];
        };
      }
      {
        why = "an add-on entry naming a manager";
        entry = {
          mode = "addOn";
          managedBy = "x";
          activities = [ ];
        };
      }
      {
        why = "a full entry naming a manager";
        entry = {
          mode = "full";
          managedBy = "x";
          activities = [ "web" ];
        };
      }
      {
        why = "a full entry listing default";
        entry = {
          mode = "full";
          managedBy = null;
          activities = [ "default" ];
        };
      }
      {
        why = "an add-on entry listing default";
        entry = {
          mode = "addOn";
          managedBy = null;
          activities = [ "default" ];
        };
      }
      {
        why = "an add-on entry listing an activity twice";
        entry = {
          mode = "addOn";
          managedBy = null;
          activities = [
            "web"
            "web"
          ];
        };
      }
      {
        why = "a managedElsewhere entry selecting activities";
        entry = {
          mode = "managedElsewhere";
          managedBy = null;
          activities = [ "web" ];
        };
      }
      {
        why = "an empty pointer";
        entry = {
          mode = "managedElsewhere";
          managedBy = "";
          activities = [ ];
        };
      }
    ]
    ++ expectTrue "hostSystemManagement refuses an entry for an undeclared host" (
      fails (reprobuildLib.hostSystemManagement {
        document = neutral // {
          intent = neutral.intent // {
            hostSystems = neutral.intent.hostSystems // {
              "gm10-nowhere" = {
                mode = "addOn";
                managedBy = null;
                activities = [ ];
              };
            };
          };
        };
        host = "m1";
      })
    )
    # The evaluation refuses the same malformed table rather than reading
    # the host as managed here.
    ++ expectTrue "readIntent refuses a malformed hostSystems" (
      refusedSnapshot "malformed-system" (
        neutral
        // {
          intent = neutral.intent // {
            hostSystems = {
              "m1" = {
                mode = "managedElsewhere";
                managedBy = "";
                activities = [ ];
              };
            };
          };
        }
      )
    );

  failures =
    systemManagementTests
    ++ profileBinTests
    ++ predicateTests
    ++ dataSelectionTests
    ++ dataRejectionTests
    ++ dataThrowTests
    ++ intentTests
    ++ refusalTests
    ++ realizationTests
    ++ brewTests;

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
