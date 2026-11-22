## TC-8e — certificate issuance on a SHARDED ``repro test`` run
## (Test-Certificates.md §"Issuance on a sharded run"; CI-Sharding.md
## §"Relationship To ``ct-test-runner``").
##
## ``app`` declares three test edges, ``unit_a``, ``side`` and ``unit_b``,
## ``unit-suite`` (``unit_a`` + ``unit_b``), ``side-suite`` (``side``) and an
## ``aggregate("test", ...)`` over all three, in the order ``unit_a``,
## ``side``, ``unit_b``. With no cost history the planner slices the test
## commands in that order, so of two shards shard 1 runs ``unit_a`` and
## ``unit_b`` and shard 2 runs ``side``. Then:
##
##   1. ``--emit-partition-plan`` writes the plan, runs nothing, and records
##      which shard certifies each marked node: ``unit-suite`` shard 1,
##      ``side-suite`` shard 2, ``test`` none (it is split), and says so;
##   2. a ``--plan-from`` made for another selection is refused;
##   3. shard 1 executes exactly ``unit_a`` and ``unit_b`` and issues a signed
##      certificate for ``unit-suite``, bound to the working tree's content and
##      recording the two argv it executed. It issues nothing for ``test`` and
##      says it ran 2 of its 3 test commands; its report carries the per-test
##      outcome and the certificate verdicts;
##   4. shard 2 executes exactly ``side`` and certifies ``side-suite``; still
##      no certificate for ``test`` (1 of 3);
##   5. the split node is certified afterwards, unsharded, by ``repro
##      certify test`` on the same host. The shards left every command's
##      outputs in place, so the engine reports the three commands up to date
##      without consulting a cache record; such a result cannot be attested
##      (D16 needs a key-matched record with byte-identical inputs), so
##      ``repro certify`` re-executes the three, says so, and records all
##      three in the certificate;
##   6. a failing test command (``side``'s input set to FAIL) fails its shard
##      and issues nothing for ``side-suite``, naming why.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and filesystem monitor, the production signer and local
## certificate store. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[algorithm, json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    certificate \"unit-suite\", aggregate(\"unit-suite\", @[unit_a, unit_b])\n" &
  "    certificate \"side-suite\", side\n" &
  "    discard aggregate(\"test\", @[unit_a, side, unit_b])\n"

proc outputNames(paths: seq[string]): seq[string] =
  ## The output files' names, sorted: the engine may hand the tool absolute
  ## paths, and parallel edges have no fixed relative order.
  for path in paths:
    result.add(path.extractFilename)
  result.sort()

proc certificateEntry(doc: JsonNode; name: string): JsonNode =
  for entry in doc["certificates"].elems:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

suite "TC-8e — a shard certifies only the nodes it ran whole":

  test "t_repro_test_shard_certifies_only_nodes_it_ran_whole":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("tc8e-shard",
        ["unit_a", "side", "unit_b"], buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let content = fx.contentNow()
      let planPath = fx.cf.sib.scratch / "plan.json"

      # ---- 1. the plan says which shard certifies what ----------------------
      let emitted = fx.reproIn(["test", "--tool-provisioning=path",
        "--shard", "1/2", "--emit-partition-plan=" & planPath])
      checkpoint(emitted.output)
      check emitted.code == 0
      check fx.executedOutputs().len == 0
      check fx.storedCount() == 0
      check "'test' is split across shards 1, 2 of 2" in emitted.output
      let plan = parseJson(readFile(planPath))
      check plan.certificateEntry("unit-suite")["certifying_shard"].getInt() == 1
      check plan.certificateEntry("side-suite")["certifying_shard"].getInt() == 2
      check plan.certificateEntry("test")["certifying_shard"].kind == JNull
      check plan.certificateEntry("test")["test_commands"].len == 3

      # ---- 2. a plan for another selection is refused -----------------------
      let stale = fx.reproIn(["test", "--tool-provisioning=path",
        "--shard", "1/2", "--plan-from=" & planPath, "unit-suite"])
      checkpoint(stale.output)
      check stale.code == 2
      check "was made for a different selection" in stale.output
      check fx.executedOutputs().len == 0

      # ---- 3. shard 1 runs unit_a and unit_b and certifies unit-suite --------
      let report1 = fx.cf.sib.scratch / "shard-1.json"
      let shard1 = fx.reproIn(["test", "--tool-provisioning=path",
        "--shard", "1/2", "--plan-from=" & planPath,
        "--write-report=" & report1])
      checkpoint(shard1.output)
      check shard1.code == 0
      check outputNames(fx.executedOutputs()) ==
        @["unit_a-out", "unit_b-out"]
      let unit = fx.certificatesFor(content, "unit-suite")
      check unit.len == 1
      if unit.len == 1:
        check unit[0].isSigned
        check unit[0].vcs.content == content
        check outputNames(unit[0].commandOutputs()) ==
          @["unit_a-out", "unit_b-out"]
        for command in unit[0].commands:
          # The argv the engine launched: the typed tool and its flags.
          check command.argv.len > 0
          check command.argv[0].endsWith("cert-tool")
          check "--input" in command.argv
      check fx.certificatesFor(content, "test").len == 0
      check fx.certificatesFor(content, "side-suite").len == 0
      check "no certificate for 'test' from this shard — shard 1/2 ran 2 " &
        "of its 3 test commands" in shard1.output
      check "not certified by shard 1/2: side-suite" in shard1.output
      check fx.storedCount() == 1
      let r1 = parseJson(readFile(report1))
      check r1["mode"].getStr() == "workspace"
      check r1["test_pass_count"].getInt() == 2
      check r1["test_fail_count"].getInt() == 0
      check r1["tests"].len == 2
      for entry in r1["tests"].elems:
        check entry["passed"].getBool()
        check entry["argv"].len > 0
      check r1.certificateEntry("unit-suite")["issued"].getBool()
      check not r1.certificateEntry("test")["issued"].getBool()
      check fileExists(r1["partition_file"].getStr())

      # ---- 4. shard 2 runs side and certifies side-suite ---------------------
      let shard2 = fx.reproIn(["test", "--tool-provisioning=path",
        "--shard", "2/2", "--plan-from=" & planPath,
        "--write-report=" & fx.cf.sib.scratch / "shard-2.json"])
      checkpoint(shard2.output)
      check shard2.code == 0
      check outputNames(fx.executedOutputs()) ==
        @["side-out", "unit_a-out", "unit_b-out"]
      let side = fx.certificatesFor(content, "side-suite")
      check side.len == 1
      if side.len == 1:
        check side[0].isSigned
        check outputNames(side[0].commandOutputs()) == @["side-out"]
      check fx.certificatesFor(content, "test").len == 0
      check "no certificate for 'test' from this shard — shard 2/2 ran 1 " &
        "of its 3 test commands" in shard2.output
      check fx.storedCount() == 2

      # ---- 5. the split node, certified after the shards on this host --------
      let combined = fx.reproIn(["certify", "--tool-provisioning=path",
        "test"])
      checkpoint(combined.output)
      check combined.code == 0
      check "repro certify: re-executing 3 action(s) whose cached results " &
        "cannot be attested" in combined.output
      # Each of the three ran once more, in this run.
      check outputNames(fx.executedOutputs()) ==
        @["side-out", "side-out", "unit_a-out", "unit_a-out", "unit_b-out",
          "unit_b-out"]
      let whole = fx.certificatesFor(content, "test")
      check whole.len == 1
      if whole.len == 1:
        check outputNames(whole[0].commandOutputs()) ==
          @["side-out", "unit_a-out", "unit_b-out"]
      check fx.storedCount() == 3

      # ---- 6. a failing test command issues nothing --------------------------
      writeFile(fx.app / "src" / "side.txt", "FAIL side\n")
      let failing = fx.contentNow()
      check failing != content
      let report2 = fx.cf.sib.scratch / "shard-2-failing.json"
      let shard2f = fx.reproIn(["test", "--tool-provisioning=path",
        "--shard", "2/2", "--plan-from=" & planPath,
        "--write-report=" & report2])
      checkpoint(shard2f.output)
      check shard2f.code != 0
      check fx.certificatesFor(failing, "side-suite").len == 0
      check "no certificate for 'side-suite' — it did not pass" in
        shard2f.output
      let r2 = parseJson(readFile(report2))
      check r2["test_fail_count"].getInt() == 1
      check not r2["tests"][0]["passed"].getBool()
      check not r2.certificateEntry("side-suite")["issued"].getBool()
      check fx.storedCount() == 3
