## The provider compile is served to a byte-identical copy of the recipe at
## another path, and the provider it serves works THERE.
##
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles", stage 2 (owner decision 2026-10-11, "relative on the wire"):
## the provider-compile edge runs in the recipe's directory, is keyed by
## recipe-relative identities, writes its outputs under the action-cache
## root, and produces a binary that names the recipe's own files relative to
## the recipe. The engine launches it with its working directory at the
## project root and resolves the relative paths in its responses there
## (Provider-Runtime-Protocol-v1.md, "Paths in responses").
##
## Measured before the change (agents @ 652dce595, same fixture): the copy at
## B paid a full provider compile (61 s of a 61 s build). The properties:
##
##   * SERVED: the copy at B does not run the compiler (witness compiler
##     count) and the provider-compile line says so;
##   * CORRECT AT B: the project-root fallback for a package the provider
##     does not own names B's directory, and B's provider-graph snapshot
##     records B's recipe as its evaluation input, not A's;
##   * NOT OVER-SHARED: an edit to B's recipe compiles again;
##   * NOT SHARED WHEN LOCATION-BOUND: a recipe whose provider bakes in its
##     own absolute location (`currentSourcePath()`) is compiled at each
##     copy, so each copy evaluates its own paths and keeps its cache hits.
##     Both shapes: the directory folded into a `const`, and the source
##     path itself read at run time, which spells exactly what the
##     compiler's line information spells (reprobuild-pm issue
##     `2026-11-19-a-cached-provider-compile-is-reused-across-checkouts-so-currentsourcepath-names-another-checkout.md`);
##   * SHARED WHEN ONLY THE DSL RECORDS A SITE: a recipe that declares a
##     `certificate`, a `contribute:` entry, an `environment`, an
##     `instanceOverrides` block, an activity with a parameter and a
##     `config:` key, a shared service and a resolver of it, a `lockFile`
##     and a variant -- and does not
##     read its own location -- is served to the second copy, and the sites
##     it reports name THAT copy (issue 2026-11-20, "DSL sites recorded
##     absolute make their provider location-bound").
##
## MOCK POLICY - none. The real `build/bin/repro` drives real compiles; the
## only stand-in is a shell wrapper around the real `nim` that counts
## provider compiles before exec'ing it.

import std/[json, os, osproc, sequtils, strutils, unittest]

const OtherModule = """
import repro_project_dsl

package relocother:
  build:
    discard
"""

const Recipe = """
import repro_project_dsl
import other

package relocprobe:
  build:
    fs.writeText(actionId = "write-root", output = "out/root.txt",
      text = packageProjectRoot("relocother") & "\n")
"""

const BakedRecipe = """
import std/os
import repro_project_dsl
import other

const recipeRoot = parentDir(currentSourcePath())

package relocprobe:
  build:
    fs.writeText(actionId = "write-baked-root", output = "out/root.txt",
      text = recipeRoot & "\n")
"""

const CertifiedRecipe = """
import repro_project_dsl
import other

package relocprobe:
  build:
    let root = fs.writeText(actionId = "write-root", output = "out/root.txt",
      text = packageProjectRoot("relocother") & "\n")
    certificate "unit-suite", root
"""

const DevEnvRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/lock_file_decl
import other

## The tools this probe runs on the build machine.
lockFile probeTools

package relocowner:
  config:
    issuer: string = "http://localhost:8080"
    flavour: variant string = "debug"

  devEnv:
    activity sso(host: string):
      config:
        relyingParties: seq[string] = @["owner"]

      service idp:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        args relyingParties
        identity stable "com.example.reloc.idp"
        scope workspace
        workingDirectory "."
        readiness fileExists(".repro/reloc/idp-ready")
        instance:
          lease keep
        converge relyingParties

    enable sso("localhost")

  environment dev:
    issuer = "https://login.example.test"

  build:
    let root = fs.writeText(actionId = "write-root", output = "out/root.txt",
      text = packageProjectRoot("relocother") & "\n")
    certificate "unit-suite", root

package relocconsumer:
  contribute:
    append:
      relocowner.sso.relyingParties = "contributed"

  instanceOverrides relocowner.idp:
    scope workspace
    lease keep

  devEnv:
    activity stack(sso: SharedServiceHandle[LiftedServiceHandle]):
      service app:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.reloc.app"
        scope project

    enable stack(sso = relocowner.sso.idp.shared(
      relyingParties = append("resolved")))
"""

const RunTimeSourcePathRecipe = """
import std/os
import repro_project_dsl
import other

package relocprobe:
  build:
    fs.writeText(actionId = "write-checkout-name", output = "out/root.txt",
      text = currentSourcePath().parentDir().parentDir().lastPathPart & "\n")
"""

const ProviderLinePrefix = "providerCompileAction: __repro_provider_compile"

proc providerLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(ProviderLinePrefix):
      return stripped
  ""

proc compileCount(log: string): int =
  if not fileExists(log):
    return 0
  for line in readFile(log).splitLines:
    if line == "provider":
      inc result

proc writeProject(dir, recipe: string) =
  createDir(dir)
  writeFile(dir / "other.nim", OtherModule)
  writeFile(dir / "repro.nim", recipe)

proc build(reproBin, witness, projectRoot, actionCacheRoot, storeRoot: string):
    tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    "env",
    "REPRO_NIM_COMPILER=" & witness,
    "REPROBUILD_STORE_ROOT=" & storeRoot,
    "REPRO_STORE_ROOT=" & storeRoot,
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    "--log=actions",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode)

proc verdictsUnder(root: string): seq[string] =
  ## Every recipe-relative provider-compile verdict written under `root`
  ## (`recipeRelativeProviderVerdictPath`), wherever the engine kept the
  ## edge's outputs: in staging, or in a published computation directory.
  for path in walkDirRec(root):
    if extractFilename(path) == "relocation-verdict":
      result.add(readFile(path).strip())

proc snapshotOf(projectRoot: string): string =
  for path in walkDirRec(projectRoot / ".repro"):
    if extractFilename(path) == "provider-fragments.rbsz":
      return readFile(path)
  ""

type RelocFixture = object
  ## Two byte-identical copies of a project at the same depth (the
  ## relocatable record is keyed on the depth of its working directory),
  ## one shared action-cache root, and a witness `nim` that counts provider
  ## compiles before exec'ing the real one.
  tempRoot, compileLog, witness, actionCacheRoot, storeRoot: string
  projectA, projectB: string

proc newRelocFixture(prefix, recipe: string): RelocFixture =
  let nim = findExe("nim")
  result.tempRoot = expandFilename("/tmp") /
    (prefix & $getCurrentProcessId())
  removeDir(result.tempRoot)
  createDir(result.tempRoot)
  result.compileLog = result.tempRoot / "provider-compiles"
  result.witness = result.tempRoot / "witness-nim"
  writeFile(result.witness, "#!/bin/sh\n" &
    "case \"$*\" in\n" &
    "  *--define:reproProviderMode*) echo provider >> " &
      quoteShell(result.compileLog) & " ;;\n" &
    "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
  setFilePermissions(result.witness, {fpUserRead, fpUserWrite, fpUserExec})
  result.actionCacheRoot = result.tempRoot / "action-cache"
  result.storeRoot = result.tempRoot / "store"
  createDir(result.actionCacheRoot)
  result.projectA = result.tempRoot / "a" / "project"
  result.projectB = result.tempRoot / "b" / "project"
  writeProject(result.projectA, recipe)
  writeProject(result.projectB, recipe)

proc reproAt(reproBin: string; fx: RelocFixture; project: string;
             args: openArray[string]): string =
  ## Run `repro <args>` in `project` against the fixture's store and its
  ## shared action-cache root (so a command that needs the provider is
  ## served the same binary the builds were), and return its output.
  var argv = @["env",
    "REPRO_NIM_COMPILER=" & fx.witness,
    "REPROBUILD_STORE_ROOT=" & fx.storeRoot,
    "REPRO_STORE_ROOT=" & fx.storeRoot,
    "REPROBUILD_ACTION_CACHE_ROOT=" & fx.actionCacheRoot,
    reproBin]
  for arg in args:
    argv.add(arg)
  let res = execCmdEx(quoteShellCommand(argv), workingDir = project)
  checkpoint(res.output)
  require res.exitCode == 0
  res.output

proc jsonDocument(output, schemaId: string): JsonNode =
  ## The JSON document with `schemaId` that a `--json` command printed.
  let at = output.find("{\"schemaId\":\"" & schemaId & "\"")
  require at >= 0
  parseJson(output[at .. ^1].splitLines()[0])

proc certificateSites(reproBin: string; fx: RelocFixture;
                      project: string): seq[string] =
  ## `<source-file>:<source-line>` of every declared certificate `repro
  ## certificates list` reports for `project`, read from the stored graph.
  let listed = jsonDocument(reproAt(reproBin, fx, project,
    ["certificates", "list", "--json", "--tool-provisioning=path"]),
    "reprobuild.certificates-list.v1")
  for entry in listed["certificates"]:
    if not entry["implicit"].getBool():
      result.add(entry["source-file"].getStr() & ":" &
        $entry["source-line"].getInt())

proc targetSite(reproBin: string; fx: RelocFixture;
                project, name: string): string =
  ## The source file `repro build --list-targets` reports for target `name`.
  let listed = jsonDocument(reproAt(reproBin, fx, project,
    ["build", "--list-targets", "--json", "--daemon=off",
     "--tool-provisioning=path"]), "reprobuild.list-targets.v1")
  for entry in listed["targets"]:
    if entry["name"].getStr() == name:
      return entry["source-file"].getStr()
  ""

proc lockList(reproBin: string; fx: RelocFixture; project: string): string =
  ## What `repro lock list` prints for `project`: each declared lock file
  ## with the site that declared it.
  reproAt(reproBin, fx, project, ["lock", "list"])

proc filesNaming(root, needle: string): seq[string] =
  ## Every file under `root/.repro` whose bytes contain `needle`, except the
  ## two that carry the shared compile's OWN diagnostics, which
  ## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
  ## compiles" accepts naming the copy that compiled them: the provider
  ## binary (compiler line information in stack-trace frames) and the
  ## caller's provider-compile artifact (its execution result is the
  ## compiler's output, whose warnings and hints name the compiling copy's
  ## files). Everything else B holds was evaluated or recorded for B.
  for path in walkDirRec(root / ".repro"):
    if extractFilename(path) in ["project-provider", "provider-compile.rbsz"]:
      continue
    if needle in readFile(path):
      result.add(relativePath(path, root))

proc servedAtTheSecondCopy(reproBin: string; fx: RelocFixture) =
  ## A builds and compiles the provider; B, the same bytes at another path,
  ## is served A's binary without a compile, and the binary runs AT B.
  let first = build(reproBin, fx.witness, fx.projectA, fx.actionCacheRoot,
    fx.storeRoot)
  if first.exitCode != 0:
    checkpoint(first.output)
  require first.exitCode == 0
  let compiledAtA = compileCount(fx.compileLog)
  checkpoint("A: " & providerLine(first.output))
  checkpoint("verdicts: " & $verdictsUnder(fx.tempRoot))
  check compiledAtA >= 1
  check readFile(fx.projectA / "out" / "root.txt").strip() == fx.projectA

  let second = build(reproBin, fx.witness, fx.projectB, fx.actionCacheRoot,
    fx.storeRoot)
  if second.exitCode != 0:
    checkpoint(second.output)
  require second.exitCode == 0
  let lineAtB = providerLine(second.output)
  checkpoint("B: " & lineAtB)
  # SERVED: no compiler ran for B, because A's binary was judged
  # relocatable.
  check compileCount(fx.compileLog) == compiledAtA
  check "launched=false" in lineAtB
  check "compiled=false" in lineAtB
  check readFile(fx.projectB / "out" / "root.txt").strip() == fx.projectB

suite "the provider compile follows the recipe":

  test "a copy at another path is served, and its provider runs there":
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let nim = findExe("nim")
    if not fileExists(reproBin) or nim.len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      # A short root, and A and B at the same depth: the relocatable record
      # is keyed on the depth of its working directory.
      let tempRoot = expandFilename("/tmp") /
        ("rb-provreloc-" & $getCurrentProcessId())
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let compileLog = tempRoot / "provider-compiles"
      let witness = tempRoot / "witness-nim"
      writeFile(witness, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproProviderMode*) echo provider >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      setFilePermissions(witness, {fpUserRead, fpUserWrite, fpUserExec})
      let actionCacheRoot = tempRoot / "action-cache"
      let storeRoot = tempRoot / "store"
      createDir(actionCacheRoot)
      let projectA = tempRoot / "a" / "project"
      let projectB = tempRoot / "b" / "project"
      writeProject(projectA, Recipe)
      writeProject(projectB, Recipe)

      let first = build(reproBin, witness, projectA, actionCacheRoot,
        storeRoot)
      if first.exitCode != 0:
        checkpoint(first.output)
      require first.exitCode == 0
      let compiledAtA = compileCount(compileLog)
      checkpoint("A: " & providerLine(first.output))
      check compiledAtA >= 1
      check readFile(projectA / "out" / "root.txt").strip() == projectA

      # --- B: the same bytes at another path. ---------------------------
      let second = build(reproBin, witness, projectB, actionCacheRoot,
        storeRoot)
      if second.exitCode != 0:
        checkpoint(second.output)
      require second.exitCode == 0
      let lineAtB = providerLine(second.output)
      checkpoint("B: " & lineAtB)
      # SERVED: no compiler ran for B.
      check compileCount(compileLog) == compiledAtA
      check "launched=false" in lineAtB
      check "compiled=false" in lineAtB
      # CORRECT AT B: the provider resolves the recipe's own paths at B.
      check fileExists(projectB / ".repro" / "build" / "repro" / "provider" /
        "project-provider")
      check readFile(projectB / "out" / "root.txt").strip() == projectB
      let snapshotB = snapshotOf(projectB)
      check snapshotB.len > 0
      check (projectB / "repro.nim") in snapshotB
      check projectA notin snapshotB

      # --- NOT OVER-SHARED: B's own edit compiles. ----------------------
      writeFile(projectB / "repro.nim", Recipe & "# edited at B\n")
      let edited = build(reproBin, witness, projectB, actionCacheRoot,
        storeRoot)
      if edited.exitCode != 0:
        checkpoint(edited.output)
      require edited.exitCode == 0
      checkpoint("B edited: " & providerLine(edited.output))
      check compileCount(compileLog) > compiledAtA
      check readFile(projectB / "out" / "root.txt").strip() == projectB

  test "a recipe that bakes in its own location is compiled at each location":
    # `currentSourcePath()` is absolute in a recipe-relative compile too, and
    # a recipe may evaluate it (CodeTracer: `projectRootPath =
    # parentDir(currentSourcePath())` in a `const`, joined onto every
    # `--path` of its `nim js` edges). Served to another copy, such a binary
    # evaluates the copy that COMPILED it. Measured at 5276f7284 with this
    # shape of recipe and one shared action-cache root: A, then B (which
    # recompiled the shared binary), then A again wrote B's directory into
    # A's output and re-ran A's action - the key moved between two builds of
    # an unchanged tree, and the output named the wrong project.
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let nim = findExe("nim")
    if not fileExists(reproBin) or nim.len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      let tempRoot = expandFilename("/tmp") /
        ("rb-provbaked-" & $getCurrentProcessId())
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let compileLog = tempRoot / "provider-compiles"
      let witness = tempRoot / "witness-nim"
      writeFile(witness, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproProviderMode*) echo provider >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      setFilePermissions(witness, {fpUserRead, fpUserWrite, fpUserExec})
      let actionCacheRoot = tempRoot / "action-cache"
      let storeRoot = tempRoot / "store"
      createDir(actionCacheRoot)
      let projectA = tempRoot / "a" / "project"
      let projectB = tempRoot / "b" / "project"
      writeProject(projectA, BakedRecipe)
      writeProject(projectB, BakedRecipe)

      for (label, project) in [("A", projectA), ("B", projectB),
                               ("A again", projectA)]:
        let res = build(reproBin, witness, project, actionCacheRoot,
          storeRoot)
        if res.exitCode != 0:
          checkpoint(res.output)
        require res.exitCode == 0
        checkpoint(label & ": " & providerLine(res.output))
        # CORRECT AT EACH COPY: the baked location is this copy's own.
        check readFile(project / "out" / "root.txt").strip() == project
        if label == "A again":
          # STABLE: nothing changed at A, so its edge is not re-run.
          check "action: write-baked-root status=asUpToDate" in res.output
      # B could not be served A's binary: it compiled its own.
      check compileCount(compileLog) >= 2

  test "a recipe that declares a certificate is served at another location":
    # Issue 2026-11-20: `certificate "<name>", <handle>` recorded its site
    # with `instantiationInfo(fullPaths = true)`, so the binary held
    # `<recipe directory>/repro.nim` as a string value and was judged
    # location-bound: every copy paid a compile. Recorded through
    # `recipeSourceName`, the site is relative to the recipe, the binary is
    # shared, and the engine reports the site at the copy that asks.
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin) or findExe("nim").len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      let fx = newRelocFixture("rb-provcert-", CertifiedRecipe)
      defer: removeDir(fx.tempRoot)
      servedAtTheSecondCopy(reproBin, fx)
      check verdictsUnder(fx.tempRoot) == @["relocatable"]
      # CORRECT AT B: what B reports names B's recipe, not A's. On a
      # verdict that shares a binary holding absolute DSL sites, B is
      # served A's binary and reports A's file for each of these.
      checkpoint("B files naming A: " & $filesNaming(fx.projectB,
        fx.projectA))
      check filesNaming(fx.projectB, fx.projectA).len == 0
      check targetSite(reproBin, fx, fx.projectB, "unit-suite") ==
        fx.projectB / "repro.nim"
      var declLine = 0
      let recipeLines = CertifiedRecipe.splitLines()
      for i, line in recipeLines:
        if line.strip().startsWith("certificate "):
          declLine = i + 1
      check certificateSites(reproBin, fx, fx.projectB) ==
        @[fx.projectB / "repro.nim" & ":" & $declLine]

  test "a recipe using the dev-env and shared-service constructs is served":
    # The other sites the issue lists, and two more found binding the same
    # way (a `lockFile` declaration's run-time half, measured location-bound
    # on its own): a `contribute:` entry, an
    # `environment` and its binding, an `instanceOverrides` block, an
    # activity's declaration, parameter and `config:` key, a service
    # signature, a shared service's declaration (its owner directory) and
    # a resolver of it with a contribution. None of them is a location the
    # recipe asked for, so none may bind the provider to its copy.
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin) or findExe("nim").len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      let fx = newRelocFixture("rb-provdevenv-", DevEnvRecipe)
      defer: removeDir(fx.tempRoot)
      servedAtTheSecondCopy(reproBin, fx)
      check verdictsUnder(fx.tempRoot) == @["relocatable"]
      # CORRECT AT B: every site B reports names B's recipe, not A's --
      # the certificate, the target it exports, the lock file, and the
      # dev-env evaluation's shared resolution (its owner directory and
      # sites), which `repro dev-env export` records under B's `.repro`.
      check certificateSites(reproBin, fx, fx.projectB).len == 1
      for site in certificateSites(reproBin, fx, fx.projectB):
        check site.startsWith(fx.projectB / "repro.nim" & ":")
      check targetSite(reproBin, fx, fx.projectB, "unit-suite") ==
        fx.projectB / "repro.nim"
      let listed = lockList(reproBin, fx, fx.projectB)
      check "probeTools" in listed
      check (fx.projectB / "repro.nim") in listed
      check fx.projectA notin listed
      for project in [fx.projectA, fx.projectB]:
        discard reproAt(reproBin, fx, project,
          ["dev-env", "export", "--project-root=" & project, "bash"])
      checkpoint("B files naming A: " & $filesNaming(fx.projectB,
        fx.projectA))
      check filesNaming(fx.projectB, fx.projectA).len == 0

  test "a recipe that reads its source path at run time is compiled at each location":
    # isonim-tui 915f9fc derived an output directory from
    # `currentSourcePath().parentDir().lastPathPart`, evaluated when the
    # provider runs. The binary then holds `<recipe>/repro.nim` as a string
    # value and nothing else of its location, which is the very spelling
    # every provider carries as line information. Measured on repro 0.2.23:
    # two worktrees of one commit got one provider, and the second worktree's
    # build wrote into the first.
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let nim = findExe("nim")
    if not fileExists(reproBin) or nim.len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      let tempRoot = expandFilename("/tmp") /
        ("rb-provruntime-" & $getCurrentProcessId())
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let compileLog = tempRoot / "provider-compiles"
      let witness = tempRoot / "witness-nim"
      writeFile(witness, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproProviderMode*) echo provider >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      setFilePermissions(witness, {fpUserRead, fpUserWrite, fpUserExec})
      let actionCacheRoot = tempRoot / "action-cache"
      let storeRoot = tempRoot / "store"
      createDir(actionCacheRoot)
      # Two checkouts that differ in the name the recipe reads: `a`, `b`.
      let projectA = tempRoot / "a" / "project"
      let projectB = tempRoot / "b" / "project"
      writeProject(projectA, RunTimeSourcePathRecipe)
      writeProject(projectB, RunTimeSourcePathRecipe)

      var compiledBefore = 0
      for (label, project, name) in [("A", projectA, "a"),
                                     ("B", projectB, "b"),
                                     ("A again", projectA, "a")]:
        let res = build(reproBin, witness, project, actionCacheRoot,
          storeRoot)
        let compiledNow = compileCount(compileLog)
        if label == "B":
          # B could not be served A's binary: it compiled its own.
          check compiledNow > compiledBefore
        compiledBefore = compiledNow
        if res.exitCode != 0:
          checkpoint(res.output)
        require res.exitCode == 0
        checkpoint(label & ": " & providerLine(res.output))
        # CORRECT AT EACH COPY: the name read is this checkout's own.
        check readFile(project / "out" / "root.txt").strip() == name
        if label == "A again":
          check "action: write-checkout-name status=asUpToDate" in res.output
        if label == "A":
          # BOUND BY ITS BYTES: the edge's recorded verdict names A's recipe.
          # This holds whether or not the host publishes the compile record,
          # so it discriminates even where no copy would ever be served.
          check verdictsUnder(tempRoot).anyIt(
            it.startsWith("location-bound") and (projectA / "repro.nim") in it)
