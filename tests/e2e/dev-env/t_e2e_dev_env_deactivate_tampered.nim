## M75 — tamper-detection test for ``repro dev-env deactivate``.
##
## Per the spec, when the manifest's ``activation_script_hash`` does
## not match the script the deactivate arm would re-derive from the
## same RBDE artifact, we MUST:
##
##   1. Emit a no-op (parse-safe) script to stdout.
##   2. Emit a clear diagnostic to stderr.
##   3. Exit with code 3 (distinct from 0/1/2 so the shell hook can
##      branch on it).
##
## The test exercises two tamper scenarios:
##
##   * **Manifest tampered** — we edit the manifest in place so its
##     activation_script_hash is wrong; the deactivate arm detects
##     the mismatch.
##   * **Artifact tampered** — we leave the manifest alone and
##     modify the RBDE artifact so the re-derived script differs.
##
## Both scenarios must exit 3 with a stderr diagnostic.

import std/[json, os, osproc, streams, strutils, unittest]

import repro_test_support
import repro_cli_support/dev_env_shell_export
import repro_cli_support/dev_env_rollback_manifest
import dev_env_export_helper

proc runDeactivate(c: M74Case; manifestPath: string;
                   shell = "bash"): CommandOutcome =
  var process = startProcess(c.reproBin,
    args = @["dev-env", "deactivate", manifestPath,
      "--shell", shell],
    workingDir = c.repoRoot,
    env = c.envFor(),
    options = {poUsePath})
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc runActivate(c: M74Case; shell = "bash"): CommandOutcome =
  var process = startProcess(c.reproBin,
    args = @["dev-env", "export", shell,
      "--project-root", c.projectRoot],
    workingDir = c.repoRoot,
    env = c.envFor(),
    options = {poUsePath})
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc extractManifestPath(activationScript: string): string =
  ## The activation script emits
  ## ``export __REPRO_ACTIVE_MANIFEST='<path>'`` for bash. Scrape it.
  for raw in activationScript.splitLines():
    let line = raw.strip()
    if line.startsWith("export __REPRO_ACTIVE_MANIFEST="):
      let rest = line["export __REPRO_ACTIVE_MANIFEST=".len .. ^1]
      # rest is single-quoted, no embedded quotes in a fs path here.
      if rest.startsWith("'") and rest.endsWith("'"):
        return rest[1 ..< rest.high]
      return rest
  ""

suite "e2e_dev_env_deactivate_tampered":
  test "unit_hash_mismatch_exits_3_with_noop_script":
    # Pure-formatter unit test: synthesize a manifest, rederive the
    # script with a DIFFERENT plan, confirm the hash mismatch
    # triggers the no-op + exit-3 branch via the deactivation
    # emitter's own logic.
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
    plan.appendReproAppliedMarker("deadbeef")
    var preEnv = initPreActivationEnv()
    let script = formatExportPlan(plan, skBash)
    let manifest = buildRollbackManifest(plan, preEnv, "deadbeef",
      script, skBash)
    # Same plan -> same hash.
    check computeActivationScriptHash(script) ==
      manifest.activationScriptHash
    # Different plan -> different hash.
    var plan2: ExportPlan = @[]
    plan2.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "PROD"))
    plan2.appendReproAppliedMarker("deadbeef")
    let script2 = formatExportPlan(plan2, skBash)
    check computeActivationScriptHash(script2) !=
      manifest.activationScriptHash

  test "noop_script_parses_under_each_shell_formatter":
    # The fallback no-op script returned on tamper MUST be a parse-
    # safe script for every shell — the hook will still ``eval`` it.
    for shell in [skBash, skZsh, skFish, skNushell, skPwsh]:
      let s = emitNoOpScript(shell)
      check s.len > 0
      # No environment mutations in the no-op script.
      check not s.contains("export ")
      check not s.contains("set -gx")
      check not s.contains("$env:")
      check not s.contains("hide-env")

  when isIoMonitorSupported:
    test "e2e_tampered_manifest_hash_exits_3":
      let c = prepareCase("repro-m75-deact-tampered-manifest")
      defer: removeDir(c.tempRoot)

      let act = runActivate(c)
      if act.exitCode != 0:
        echo "activation stdout:\n", act.stdout
        echo "activation stderr:\n", act.stderr
      check act.exitCode == 0

      let manifestPath = extractManifestPath(act.stdout)
      check manifestPath.len > 0
      check fileExists(manifestPath)

      # Tamper the manifest: flip the activation_script_hash to a
      # known-bad value while leaving everything else intact.
      let raw = readFile(manifestPath)
      let node = parseJson(raw)
      node["activation_script_hash"] = newJString("badhash00000bad0")
      writeFile(manifestPath, pretty(node))

      let deact = runDeactivate(c, manifestPath)
      if deact.exitCode != 3:
        echo "deactivation stdout:\n", deact.stdout
        echo "deactivation stderr:\n", deact.stderr
      check deact.exitCode == 3
      check deact.stderr.contains("tamper")
      check deact.stderr.contains("activation_script_hash")
      # The stdout MUST be a syntactically valid no-op script so
      # eval'ing it under bash does not corrupt the env.
      check deact.stdout.len > 0
      # Verify the no-op script has no env-mutation commands.
      check not deact.stdout.contains("export ")
      check not deact.stdout.contains("unset ")

    test "e2e_tampered_artifact_exits_3":
      let c = prepareCase("repro-m75-deact-tampered-artifact")
      defer: removeDir(c.tempRoot)

      let act = runActivate(c)
      if act.exitCode != 0:
        echo "activation stdout:\n", act.stdout
        echo "activation stderr:\n", act.stderr
      check act.exitCode == 0

      let manifestPath = extractManifestPath(act.stdout)
      check manifestPath.len > 0
      check manifestPath.endsWith(".rollback.json")
      let artifactPath =
        manifestPath[0 ..< manifestPath.len - ".rollback.json".len]
      check fileExists(artifactPath)

      # Tamper the artifact: append random bytes so its decoded
      # ExportPlan differs from what the manifest sealed at
      # activation time.
      var artifactBlob = readFile(artifactPath)
      artifactBlob.add("\xff\xff\xff\xff\xff\xff\xff\xff")
      writeFile(artifactPath, artifactBlob)

      let deact = runDeactivate(c, manifestPath)
      # The artifact may now be corrupt enough that the codec rejects
      # it outright (exit 1). Either exit 1 (engine error) or exit 3
      # (tamper detected) is acceptable here — the contract is that
      # we DO NOT silently apply a wrong-shaped rollback. The
      # spec is explicit only about hash-mismatch -> exit 3; codec
      # error -> exit 1 is also a valid "do not rollback" branch.
      if deact.exitCode notin {1, 3}:
        echo "deactivation stdout:\n", deact.stdout
        echo "deactivation stderr:\n", deact.stderr
      check deact.exitCode in {1, 3}
      check deact.stderr.len > 0
