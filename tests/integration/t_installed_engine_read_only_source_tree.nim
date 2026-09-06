## F0.6 — an engine whose OWN source tree is read-only must still build a
## project that lives somewhere else, and a scratch root that genuinely cannot
## be written must fail with a diagnostic rather than an unhandled exception.
##
## ## The defect these cases pin
##
## `usesImportCode` (`repro_project_dsl/macros_a.nim`) locates the reprobuild
## checkout by walking up from the consumer recipe, then from
## `$REPROBUILD_REPO_ROOT` / `$REPROBUILD_SRC`, then — the case that matters —
## from the DSL module's own `currentSourcePath()`. For an engine installed
## from a binary cache that last anchor lands inside `/nix/store/<hash>-source`,
## and the accessor cache was anchored at `<that>/build/nimcache/...`. Creating
## it raised, in the Nim VM, an `OSError` that unwinds past the VM's own
## `try`/`except` and out of the compiler:
##
##     Error: unhandled exception: Read-only file system
##     Additional info: /nix/store/…-source/build/ [OSError]
##
## Every `repro` verb died that way in any project that did not shadow the
## installed engine with a checkout of its own. The same shape hit a second
## consumer of the same anchor: `resolveProducerTypedContract` handed the
## interface lift `workDir = reprobuildLibraryWorkDir()` with no `scratchDir`,
## and the lift's temp tree defaulted to `<workDir>/build`.
##
## The anchor itself is NOT the bug and is not removed here. It still names the
## checkout whose `config.nims` and `libs/` the generator compile resolves
## against — it is a READ anchor. What changed is that nothing WRITES to it:
## scratch is derived from the project being built (`dslScratchRootFor`).
##
## ## No mocks
##
## Nothing here is mocked. The engine source tree is a real copy of this
## repository's `libs/` + `config.nims` + `reprobuild.nimble` made genuinely
## unwritable with real permission bits; the consumer is a real recipe compiled
## by the real `nim` in a subprocess; the assertions are on the real filesystem
## and the real compiler diagnostics. That is deliberate: the defect is a
## filesystem-permission interaction inside the Nim VM, and any test double for
## the permission boundary would have tested the double.
##
## ## Falsifiability
##
## Case 1 fails (with the original `Read-only file system` traceback) if the
## accessor scratch is re-anchored on the engine checkout, and asserts BEFORE
## compiling that the engine tree really is unwritable — so it cannot silently
## degrade into "ran a writable engine". Case 2 fails if the unwritable-root
## path goes back to a bare `createDir`, because it asserts on the content of
## the message, not merely on a non-zero exit.

import std/[compilesettings, os, osproc, strutils, unittest]

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

const compileSearchPaths = querySettingSeq(searchPaths)
  ## THIS binary's own resolved `--path` set, captured at its compile. Case 1
  ## replays it with every in-repo entry rewritten onto the read-only engine
  ## copy, which is how the DSL that expands the foreign consumer comes from
  ## the read-only tree — the same way the nix-store `repro` hands a recipe
  ## compile a `--path` list pointing into its own store source.

# ---------------------------------------------------------------------------
# Fixture recipes. A resource-declaring PRODUCER and a CONSUMER that `uses:`
# it — the only `uses:` shape that reaches the accessor-cache code path.
# ---------------------------------------------------------------------------

const producerRepro = """
import repro_project_dsl
import repro_resources
import std/options

type
  ContainerAttrs = object
    image*: string
    cpus*: int

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: cIdentity(inst), present: true)

let containerDriver = ResourceProviderDriver(
  identity: cIdentity, digest: cDigest, observe: cObserve, apply: cApply)

resourceType "vm_harness.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int

package producer:
  executable placeholder:
    discard
"""

proc consumerRepro(producerSelector: string): string =
  ("""
import repro_project_dsl

package theconsumer:
  defaultToolProvisioning "path"

  uses:
    "$1"

  build:
    discard

proc useContainer() =
  discard container("web", image = "nginx", cpus = 2)
""" % [producerSelector])

proc accessorCacheDir(workspaceRoot, producerSelector: string): string =
  ## Where `usesImportCode` caches a producer's emitted resource accessors —
  ## anchored on the WORKSPACE holding the consumer/producer siblings, i.e. the
  ## project being built. Mirrors `dslScratchRootFor`.
  workspaceRoot / ".repro" / "build" / "dsl" / "resource-accessors" /
    producerSelector

proc writeWorkspace(ws, producerSelector: string) =
  createDir(ws / producerSelector)
  writeFile(ws / producerSelector / "repro.nim", producerRepro)
  createDir(ws / "consumer")
  writeFile(ws / "consumer" / "repro.nim", consumerRepro(producerSelector))

# ---------------------------------------------------------------------------
# Permission helpers. `chmod`-equivalents via `std/os` so the fixture does not
# depend on a `chmod` binary being on the action's PATH.
# ---------------------------------------------------------------------------

const
  ReadExecPerms = {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
                   fpOthersRead, fpOthersExec}
  ReadPerms = {fpUserRead, fpGroupRead, fpOthersRead}

proc makeTreeUnwritable(root: string) =
  ## Strip every write bit, deepest entry first so a directory is not sealed
  ## before its children have been processed.
  var dirs: seq[string] = @[]
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    if dirExists(path):
      dirs.add(path)
    else:
      setFilePermissions(path, ReadPerms)
  for i in countdown(dirs.high, 0):
    setFilePermissions(dirs[i], ReadExecPerms)
  setFilePermissions(root, ReadExecPerms)

proc makeTreeWritable(root: string) =
  ## Undo `makeTreeUnwritable` so the fixture can be removed.
  if not dirExists(root):
    return
  setFilePermissions(root, ReadExecPerms + {fpUserWrite})
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    if dirExists(path):
      setFilePermissions(path, ReadExecPerms + {fpUserWrite})
    else:
      setFilePermissions(path, ReadPerms + {fpUserWrite})

proc stageReadOnlyEngine(dest: string) =
  ## A real, self-contained reprobuild SOURCE tree at `dest`, made genuinely
  ## unwritable. `config.nims` + `reprobuild.nimble` at its root are what make
  ## the DSL's anchor walk stop there — that pair is the anchor, and staging it
  ## is what reproduces the installed-engine shape.
  createDir(dest)
  copyFile(repoRoot / "config.nims", dest / "config.nims")
  copyFile(repoRoot / "reprobuild.nimble", dest / "reprobuild.nimble")
  copyDir(repoRoot / "libs", dest / "libs")
  makeTreeUnwritable(dest)

proc enginePathFlags(engineRoot: string): seq[string] =
  ## `compileSearchPaths` with every in-repo entry re-pointed at the read-only
  ## engine copy. Out-of-repo entries (the nim stdlib, nix-store siblings) are
  ## passed through unchanged — they are not part of what is under test.
  for path in compileSearchPaths:
    if path == repoRoot:
      result.add("--path:" & engineRoot)
    elif path.isRelativeTo(repoRoot):
      result.add("--path:" & (engineRoot / path.relativePath(repoRoot)))
    else:
      result.add("--path:" & path)

proc compileConsumer(consumerRecipe, nimcache, outBin: string;
                     pathFlags: openArray[string];
                     workDir: string): tuple[ok: bool, output: string] =
  let nimExe = findExe("nim")
  doAssert nimExe.len > 0, "nim compiler not on PATH"
  var cmd = quoteShell(nimExe) & " c --compileOnly --hints:off --warnings:off"
  for flag in pathFlags:
    cmd.add(" " & quoteShell(flag))
  cmd.add(" --nimcache:" & quoteShell(nimcache))
  cmd.add(" -o:" & quoteShell(outBin))
  cmd.add(" " & quoteShell(consumerRecipe))
  let (output, code) = execCmdEx("cd " & quoteShell(workDir) & " && " & cmd)
  (code == 0, output)

suite "F0.6: an installed engine never writes into its own source":

  test "t_installed_engine_builds_a_foreign_project":
    when defined(windows):
      # The fixture cannot be built here and the defect cannot arise here.
      # Windows ignores the read-only attribute on DIRECTORIES — a directory
      # marked read-only still accepts new entries, and `setFilePermissions`
      # sets nothing else — so `makeTreeUnwritable` cannot produce a genuinely
      # unwritable tree. The pre-assertion below would then fail, i.e. this is
      # a case that CANNOT BE STAGED here, not one that would silently pass.
      # An engine installed on Windows is also not installed into an
      # immutable store.
      skip()
    else:
      # Deliberately OUTSIDE this repository: a "foreign project" must not be
      # able to reach the real checkout's `config.nims` through Nim's config
      # walk, or the engine under test would not be the read-only copy.
      let root = getTempDir() / ("repro-f06-" & $getCurrentProcessId())
      removeDir(root)
      createDir(root)
      defer:
        makeTreeWritable(root)
        removeDir(root)

      let engineRoot = root / "engine-src"
      stageReadOnlyEngine(engineRoot)

      # ---- the fixture is only meaningful if the tree really is unwritable --
      # Without this the case degrades silently into "ran a writable engine".
      check dirExists(engineRoot / "libs" / "repro_project_dsl" / "src")
      check fileExists(engineRoot / "reprobuild.nimble")
      expect OSError:
        createDir(engineRoot / "build")
      check not dirExists(engineRoot / "build")

      let producerSelector = "producer_f06_" & $getCurrentProcessId()
      let ws = root / "ws"
      writeWorkspace(ws, producerSelector)

      let compiled = compileConsumer(
        ws / "consumer" / "repro.nim",
        root / "nimcache",
        root / "consumer.bin",
        enginePathFlags(engineRoot),
        workDir = root)
      checkpoint compiled.output
      check compiled.ok

      # ---- the engine's own tree was never written to ------------------------
      check not dirExists(engineRoot / "build")

      # ---- and the scratch landed on the PROJECT under build ------------------
      let accDir = accessorCacheDir(ws, producerSelector)
      let accessorFile = accDir / (producerSelector & ".accessors.nim")
      check fileExists(accessorFile)
      if fileExists(accessorFile):
        # The producer's driver did not cross with its contract.
        let accessors = readFile(accessorFile)
        check accessors.contains("proc container*")
        check not accessors.contains("registerResourceProvider")

  test "t_unwritable_root_reports_which_path_and_why":
    when defined(windows):
      # Same reason as above: a directory cannot be made unwritable to its
      # owner on Windows through `setFilePermissions`, so the failure this
      # case is about cannot be staged.
      skip()
    else:
      # This case is about the DIAGNOSTIC, so it uses the ordinary in-repo
      # engine and makes only the WORKSPACE unwritable. The fixture lives under
      # the repo so Nim's config walk wires the consumer compile as usual.
      let base = repoRoot / "build" / "nimcache" /
        ("f06-unwritable-" & $getCurrentProcessId())
      let nimcache = base & "-nc"
      let outBin = base & ".bin"
      removeDir(base)
      createDir(base)
      defer:
        makeTreeWritable(base)
        removeDir(base)
        removeDir(nimcache)
        removeFile(outBin)

      let producerSelector = "producer_f06ro_" & $getCurrentProcessId()
      writeWorkspace(base, producerSelector)

      # Seal the WORKSPACE directory only: its children stay writable, so the
      # recipes are still readable and the only thing that cannot happen is the
      # creation of `<workspace>/.repro`.
      setFilePermissions(base, ReadExecPerms)
      expect OSError:
        createDir(base / ".repro")
      check not dirExists(base / ".repro")

      let compiled = compileConsumer(
        base / "consumer" / "repro.nim",
        nimcache,
        outBin,
        enginePathFlags(repoRoot),
        workDir = repoRoot)
      checkpoint compiled.output
      check not compiled.ok

      # It is a NAMED diagnostic, not an unhandled exception.
      check not compiled.output.contains("unhandled exception")
      check not compiled.output.contains("Traceback from system")
      # It names the path it wanted…
      check compiled.output.contains(
        accessorCacheDir(base, producerSelector))
      # …the directory that actually blocked it…
      check compiled.output.contains(base)
      # …why that path was chosen…
      check compiled.output.contains("PROJECT BEING BUILT")
      check compiled.output.contains(base / "consumer" / "repro.nim")
      # …the reason…
      check compiled.output.contains("not writable")
      # …and a remedy.
      check compiled.output.contains("REPRO_DSL_SCRATCH_ROOT")
