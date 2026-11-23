## Extracting a recipe's interface checks its `uses: nim` against the
## installed prefix's compiler (reprobuild-pm
## Distribution-And-Packaging.md §5.3, amendment N3, approved by Zahary
## Karadjov, 2026-11-04: a range that excludes the shipped release "is
## refused by the existing range check, not silently replaced").
##
## The check used to run after each call site's extraction, and a
## text-scanning test held that structure; the A15 round-4 verification
## (2026-11-07) showed it could be slipped past by a `when false:`, a
## command-syntax call, or a new direct `extractInterfaceFromModule` call.
## It now runs inside the only exported extractor, and on the lift's
## fresh-artifact path, which runs no extraction. These cases hold that by
## behaviour:
##
## * with `REPRO_INSTALLED_PREFIX_NIM` unset nothing is checked;
## * with it set, a recipe whose range excludes the release is refused by
##   `extractInterfaceFromModule`, on a cold extraction and on its warm
##   short-circuit alike, and an admitting range passes;
## * a lift is refused the same way, on its cold path (it extracts), on a
##   cold path an earlier extraction's warm record answers (no `.liftkey`, so
##   not fresh: the extractor body checks its warm short-circuit) and on its
##   fresh-artifact path (it reads the artifact back without extracting);
## * a refused cold extraction publishes nothing: an empty output directory
##   stays empty, and an earlier, admitted artifact, its stub and its warm
##   records stay byte for byte as they were.
##
## Each is falsified by removing its check (see the A15 record).
##
## *Mocking.* None: real recipes compiled by the real extractor; only the
## environment variable the bootstrap would set is set by hand.

import std/[algorithm, os, strutils, unittest]

import repro_core/installed_prefix_nim
import repro_interface_artifacts

proc recipe(usesNim: string): string =
  "import repro_project_dsl\n\n" &
  "package prefixNimCheckProbe:\n" &
  "  uses:\n" &
  "    \"" & usesNim & "\"\n" &
  "  executable placeholder:\n" &
  "    discard\n"

proc scratchRoot(tag: string): string =
  ## Per-process and per-case: the runner executes each case as its own
  ## process and runs cases of one binary concurrently.
  result = getTempDir() / ("repro-prefix-nim-extract-" &
    $getCurrentProcessId() & "-" & tag)
  removeDir(result)
  createDir(result)

template withMarker(value: string; body: untyped) =
  let present = existsEnv(InstalledPrefixNimEnvVar)
  let saved = getEnv(InstalledPrefixNimEnvVar)
  if value.len > 0: putEnv(InstalledPrefixNimEnvVar, value)
  else: delEnv(InstalledPrefixNimEnvVar)
  try:
    body
  finally:
    if present: putEnv(InstalledPrefixNimEnvVar, saved)
    else: delEnv(InstalledPrefixNimEnvVar)

proc project(base, usesNim: string): string =
  result = base / "owner"
  createDir(result)
  writeFile(result / "repro.nim", recipe(usesNim))

proc extract(projectRoot, outDir: string): ProjectInterfaceArtifact =
  createDir(outDir)
  extractInterfaceFromModule(projectRoot / "repro.nim",
    outDir / "project-interface.rbsz", outDir / "project-interface.nim",
    workDir = getCurrentDir(), consumerRoot = projectRoot)

proc usesOf(a: ProjectInterfaceArtifact): seq[string] =
  for u in a.projectInterface.toolUses:
    result.add(u.rawConstraint)

suite "extracting an interface checks its uses: nim":

  test "without the prefix route nothing is checked":
    let base = scratchRoot("unset")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    withMarker(""):
      let a = extract(root, base / "out")
      check "nim ==2.2.10" in usesOf(a)

  test "an excluding range is refused, cold and on the warm short-circuit":
    let base = scratchRoot("refused")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    # A first extraction without the route leaves the warm short-circuit
    # primed, so the second call below is answered without compiling.
    withMarker(""):
      discard extract(root, base / "warm")
    withMarker("2.3.1"):
      for outDir in [base / "cold", base / "warm"]:
        checkpoint(outDir)
        try:
          discard extract(root, outDir)
          check false
        except InstalledPrefixNimError as err:
          checkpoint(err.msg)
          check "nim ==2.2.10" in err.msg
          check "excludes Nim 2.3.1" in err.msg

  test "an admitting range passes":
    let base = scratchRoot("admitted")
    defer: removeDir(base)
    let root = project(base, "nim ^2.2")
    withMarker("2.3.1"):
      let a = extract(root, base / "out")
      check "nim ^2.2" in usesOf(a)

  test "a lift whose artifact is fresh is refused the same way":
    let base = scratchRoot("lift")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    let outDir = base / "out"
    createDir(outDir)
    let plan = interfaceLiftPlan(root / "repro.nim",
      outDir / "project-interface.rbsz", outDir / "project-interface.nim",
      workDir = getCurrentDir())
    withMarker(""):
      discard liftInterfaceArtifact(plan)
    require interfaceArtifactFresh(plan)
    withMarker("2.3.1"):
      expect InstalledPrefixNimError:
        discard liftInterfaceArtifact(plan)

  test "a cold lift is refused the same way":
    # The lift's extraction branch, with nothing recorded yet: a cold
    # extraction, checked inside the extractor body before it publishes.
    let base = scratchRoot("lift-cold")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    let outDir = base / "out"
    createDir(outDir)
    let plan = interfaceLiftPlan(root / "repro.nim",
      outDir / "project-interface.rbsz", outDir / "project-interface.nim",
      workDir = getCurrentDir())
    require not interfaceArtifactFresh(plan)
    withMarker("2.3.1"):
      try:
        discard liftInterfaceArtifact(plan)
        check false
      except InstalledPrefixNimError as err:
        checkpoint(err.msg)
        check "excludes Nim 2.3.1" in err.msg

  test "a cold lift over an extraction's warm record is refused":
    # An extraction with no marker records its warm short-circuit but no
    # `.liftkey`, so the lift is not fresh and takes its extraction branch,
    # which the warm record then answers without compiling. That answer is
    # checked inside the extractor body itself, so it is refused however the
    # lift reaches the body (A15 round-7 verification, 2026-11-07).
    let base = scratchRoot("lift-over-warm")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    let outDir = base / "out"
    withMarker(""):
      discard extract(root, outDir)
    let plan = interfaceLiftPlan(root / "repro.nim",
      outDir / "project-interface.rbsz", outDir / "project-interface.nim",
      workDir = getCurrentDir())
    require not interfaceArtifactFresh(plan)
    withMarker("2.3.1"):
      expect InstalledPrefixNimError:
        discard liftInterfaceArtifact(plan)

proc filesIn(dir: string): seq[(string, string)] =
  ## Every file under `dir`, relative, with its bytes, sorted.
  for path in walkDirRec(dir):
    result.add((path.relativePath(dir), readFile(path)))
  result.sort()

suite "a refused extraction leaves nothing of its own behind":
  # Exported readers (e.g. `m9r14fLoadInterfaceToolUses`,
  # `repro_agent_backend/stage`) read an interface from its path without
  # extracting, so a refused extraction must not publish one there
  # (A15 round-6 verification, 2026-11-07).

  test "into an empty directory it writes nothing":
    let base = scratchRoot("refused-empty")
    defer: removeDir(base)
    let root = project(base, "nim ==2.2.10")
    let outDir = base / "out"
    withMarker("2.3.1"):
      expect InstalledPrefixNimError:
        discard extract(root, outDir)
    check filesIn(outDir).len == 0

  test "over an earlier artifact it leaves that artifact as it was":
    let base = scratchRoot("refused-over")
    defer: removeDir(base)
    let root = project(base, "nim ^2.2")
    let outDir = base / "out"
    withMarker("2.3.1"):
      discard extract(root, outDir)
      let before = filesIn(outDir)
      require before.len > 0
      # The recipe now excludes the release: a cold extraction, refused.
      writeFile(root / "repro.nim", recipe("nim ==2.2.10"))
      expect InstalledPrefixNimError:
        discard extract(root, outDir)
      let after = filesIn(outDir)
      check after.len == before.len
      for i in 0 ..< min(before.len, after.len):
        checkpoint(after[i][0])
        check after[i] == before[i]

