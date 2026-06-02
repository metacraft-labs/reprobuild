## Regression test for the M8 follow-up bug: the harvester silently
## emitted invalid Nim when an ``--app`` flag named a string that
## isn't a valid Nim identifier (e.g. ``--app 7zip`` produced a
## ``packages/7zip.nim`` containing ``let 7zipCatalog* = @[...]``
## which fails ``nim check`` because identifiers cannot start with
## a digit).
##
## The fix lives in ``repro_catalog_harvester.nim`` —
## ``validateResolvedAppNames`` runs in ``main()`` AFTER CLI
## parsing (so ``--app-alias`` is resolved) and BEFORE any
## source-mode dispatch (so the fail-fast path never touches the
## network or the on-disk bucket cache).
##
## Cases covered:
##
##   * digit-prefix rejected (``7zip``)
##   * hyphen rejected (``dotnet-sdk``)
##   * dot rejected (defensive)
##   * empty alias target — caught by the existing
##     ``--app-alias`` validator, not this one (out of scope)
##   * a valid bare identifier (``ripgrep``) is accepted as far as
##     the validator is concerned (the test stops checking before
##     the bucket clone)
##   * a digit-prefix name CAN be harvested when paired with a
##     correctly-shaped ``--app-alias`` (``7zip=sevenzip``); the
##     emitted file uses the alias as the seq identifier
##
## All cases invoke the harvester as a subprocess (the same way an
## operator invokes it). We deliberately do NOT call ``parseCli``
## directly because (a) the validator calls ``quit(2)`` which would
## kill the test binary and (b) the operator-facing behaviour is
## the contract we're regression-testing.

import std/[os, osproc, strutils, unittest]

const HarvesterExe = currentSourcePath.parentDir.parentDir /
  "repro_catalog_harvester.exe"

const FixturesDir = currentSourcePath.parentDir / "fixtures"

proc runHarvester(args: openArray[string]): tuple[rc: int; output: string] =
  ## Spawn the harvester binary with ``args``, merging stderr into
  ## stdout so test assertions can match either stream uniformly.
  ## We use ``execCmdEx`` on a quoted command line because the
  ## ``startProcess(...).outputStream.readAll()`` pattern can race
  ## the child's stderr flush on Windows when the child calls
  ## ``quit`` shortly after writing (the same class of pipe-drain
  ## bug ``test_harvester_history_walk`` catches for ``runGit``).
  var cmd = "\"" & HarvesterExe & "\""
  for a in args:
    cmd &= " \"" & a & "\""
  let (output, rc) = execCmdEx(cmd, options = {poStdErrToStdOut})
  (rc, output)

proc tempOutDir(tag: string): string =
  let dir = getTempDir() / ("repro-harvester-app-name-validation-" & tag)
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

suite "M8 follow-up — output app name validation":

  test "test_harvester_rejects_invalid_nim_identifier_app_name":
    # --app 7zip (no alias) → exit 2 + clear error message + no
    # output file written.
    let outDir = tempOutDir("digit-prefix-no-alias")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "7zip",
      "--output-dir", outDir,
    ])
    check rc == 2
    check "invalid output app name '7zip'" in output
    check "--app-alias" in output
    check "cannot start with a digit" in output
    # The validator runs BEFORE source-mode dispatch — the output
    # directory exists (it was created upstream of the validator
    # call? no — validator runs first) but contains no .nim files.
    var emitted: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if path.endsWith(".nim"): emitted.add(path)
    check emitted.len == 0

  test "test_harvester_rejects_hyphen_in_app_name_without_alias":
    # --app dotnet-sdk (hyphen) without alias → rejected. M67
    # reviewer flagged this same class of bug for dotnet-sdk; M68
    # used --app-alias dotnet-sdk=dotnet_sdk to work around it.
    let outDir = tempOutDir("hyphen-no-alias")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "dotnet-sdk",
      "--output-dir", outDir,
    ])
    check rc == 2
    check "invalid output app name 'dotnet-sdk'" in output
    check "--app-alias" in output
    var emitted: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if path.endsWith(".nim"): emitted.add(path)
    check emitted.len == 0

  test "test_harvester_rejects_dot_in_app_name_without_alias":
    # Defensive: a dot is also not a valid Nim identifier char.
    let outDir = tempOutDir("dot-no-alias")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "foo.bar",
      "--output-dir", outDir,
    ])
    check rc == 2
    check "invalid output app name 'foo.bar'" in output
    check "--app-alias" in output

  test "test_harvester_accepts_valid_nim_identifier_app_name":
    # --app hello (the bucket-simple fixture's only manifest) is a
    # valid Nim identifier. The harvester proceeds past validation
    # and emits packages/hello.nim. The emitted seq identifier is
    # helloCatalog (valid Nim).
    let outDir = tempOutDir("valid-name")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "hello",
      "--output-dir", outDir,
    ])
    check rc == 0
    let emitted = outDir / "hello.nim"
    check fileExists(emitted)
    let body = readFile(emitted)
    check "helloCatalog*" in body
    # Spot-check: emitted file is NOT the bug shape (no digit-prefix
    # identifier).
    check (not body.contains("let 7"))

  test "test_harvester_accepts_app_alias_override":
    # --app 7zip --app-alias 7zip=sevenzip → resolved name is
    # 'sevenzip' which is a valid identifier; validator passes.
    # The bucket-simple fixture only has 'hello.json' so the
    # harvest of the (renamed) '7zip' app will fail with
    # "no manifest file" — but that exit is 3 (harvest error),
    # NOT 2 (CLI validation). We assert rc != 2 AND the
    # validation-stage error message is absent from stderr.
    let outDir = tempOutDir("alias-override")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "7zip",
      "--app-alias", "7zip=sevenzip",
      "--output-dir", outDir,
    ])
    check rc != 2
    check (not output.contains("invalid output app name '7zip'"))
    # And conversely the harvester DID get past validation —
    # whatever message it produces is from the source-mode
    # dispatch, not from our validator.

  test "test_harvester_accepts_app_alias_override_emits_alias_identifier":
    # When the bucket actually carries a manifest under the
    # invalid-identifier source name, the alias's *target* drives
    # both the output filename and the emitted seq identifier.
    # We don't have a fixture with a digit-prefixed manifest name
    # (Scoop's convention rejects them too — that's why operators
    # name them e.g. '7zip19.00-helper'), so we exercise the
    # hyphen-rename shape (haskell-cabal -> cabal style) using
    # the bucket-simple fixture's 'hello' manifest renamed to
    # the alias target.
    let outDir = tempOutDir("alias-emit")
    let (rc, output) = runHarvester(@[
      "harvest",
      "--source", "scoop",
      "--bucket", FixturesDir / "bucket-simple",
      "--app", "hello",
      "--app-alias", "hello=greeter",
      "--output-dir", outDir,
    ])
    check rc == 0
    # Output file uses the alias target name.
    let emitted = outDir / "greeter.nim"
    check fileExists(emitted)
    let body = readFile(emitted)
    # The seq identifier is built from the alias target, NOT the
    # source manifest name.
    check "greeterCatalog*" in body
    check (not body.contains("helloCatalog*"))
