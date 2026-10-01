## `cabal_package(...)` — the `build:`-block pipeline for a from-source
## Haskell recipe. The Haskell sibling of `cargo_package` and `node_package`.
##
## Internally: fetch → vendor (a `file+noindex` repository of the pinned
## Hackage closure, `repro_project_dsl/hackage_vendor`) → `cabal build` on a
## patched copy of the source → copy the executable to `usr/bin`.
##
## ## Against nothing but the closure
##
## cabal runs with `CABAL_DIR` pointing at a directory the vendor step owns.
## Its `config` names exactly one package repository, the vendored one, so
## the solver sees the pinned versions and nothing else; there is no Hackage
## index for it to read, so a package the manifest missed fails the plan
## instead of being downloaded. The built dependencies go to that
## directory's `store`, so nothing is read from or written to the user's own
## cabal directory, and a second build reuses them.
##
## `--offline` is NOT passed, although offline is the point: cabal 3.16
## counts unpacking a package from a `file+noindex` repository as a download
## and refuses every one of them under `--offline` (`Cabal-7125`, measured
## 2026-10-02 on nixfmt's 17-package closure). The private configuration is
## what keeps the network out instead.
##
## ## Patches
##
## `patches` are recipe-relative unified diffs (`-p1`, as `git diff` writes
## them), applied in order with `git apply` to a fresh copy of the fetched
## source on every build, never to the fetched tree itself: the fetch
## re-extracts `src/` on each run, and a patch applied in place would be
## applied twice the moment the build ran without a fresh fetch. The copy
## also keeps the fetched tree read-only, as every sibling constructor does.
## `git apply` runs with its repository discovery stopped at the scratch
## directory, so a recipe inside a git checkout does not make git resolve
## the patch's paths against that checkout's root.
##
## ## The executable
##
## `cabal list-bin <target>` names the file cabal built, so the install step
## copies exactly that rather than guessing at `dist-newstyle`'s layout,
## which varies with the platform, compiler and package version.

import std/[options, os, strutils]

import repro_project_dsl
import repro_project_dsl/hackage_vendor

import ../types/package_result

const
  FetchScratchSubdir = ".repro/fetch"
    ## The same literal (and value) every sibling constructor uses, so the
    ## `from-source-cabal` convention's fetch writes the same stamp and the
    ## engine coalesces the two.
  CabalScratchSubdir* = ".repro/build/cabal"

proc cabalWorkDir*(projectRoot: string): string =
  ## The patched copy of the source the build runs in.
  projectRoot / CabalScratchSubdir / "src"

proc cabalBuildDir*(projectRoot: string): string =
  ## cabal's `--builddir`, outside the copied source so it survives the copy.
  projectRoot / CabalScratchSubdir / "dist-newstyle"

proc cabalDestdir*(projectRoot: string): string =
  projectRoot / CabalScratchSubdir / "out"

proc cabalFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "cabal-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  ## Emit the source fetch when the recipe declared one -- the same shape as
  ## the sibling constructors' helpers, writing to the shared `.repro/fetch`
  ## path.
  if packageName.len == 0 or projectRoot.len == 0:
    return none(BuildActionDef)
  let spec = registeredFetchSpec(packageName)
  if spec.url.len == 0 or spec.hashHex.len == 0:
    return none(BuildActionDef)
  let scratch = projectRoot / FetchScratchSubdir
  createDir(scratch)
  let stamp = scratch / (spec.hashHex & ".stamp")
  let tarball = scratch / (spec.hashHex & ".tar")
  let extracted = projectRoot / extractedRel
  createDir(parentDir(extracted))
  var resolvedUrl = spec.url
  if resolvedUrl.startsWith("file:./") or resolvedUrl.startsWith("file:../"):
    resolvedUrl = "file://" &
      (projectRoot / resolvedUrl[5 .. ^1]).replace("\\", "/")
  let hashTools = @[sourceFetchHashTool(spec.hashAlg)]
  let fetchToolRefs = shellFetchToolIdentityRefs(hashTools,
    copiesDataFile = spec.kind == dfkDataFile,
    archiveUrl = resolvedUrl)
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  let staged = extracted & ".repro-extract-" & spec.hashHex
  let escapedStaged = staged.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("rm -rf \"" & escapedStaged & "\"; ")
  script.add("mkdir -p \"" & escapedStaged & "\"; ")
  script.appendCurlDownload(tarball, resolvedUrl)
  case spec.hashAlg
  of dshaSha256:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | sha256sum -c -; ")
  of dshaBlake3:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | b3sum -c -; ")
  script.appendTarExtraction(tarball, staged, spec.extractStrip)
  script.add("rm -rf \"" & escapedExtracted & "\"; ")
  script.add("mv \"" & escapedStaged & "\" \"" & escapedExtracted & "\"; ")
  script.appendVerifiedFetchStamp(stamp)
  some(buildAction(
    id = cabalFetchActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[stamp],
    declaredOutputs = @[extracted],
    fixedOutput = true,
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cabal_package.fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = fetchToolRefs))

proc cabal_package*(target: string;
                    srcDir = "src";
                    patches: seq[string] = @[];
                    destdir = "";
                    extraEnv: seq[(string, string)] = @[]):
    CabalPackageResult =
  ## Fetch → vendor → `cabal build <target>` → install, for an upstream
  ## Haskell package.
  ##
  ## `target` is a cabal target naming one executable, e.g. `exe:nixfmt`;
  ## the installed file is `usr/bin/<that executable>[.exe]`.
  ##
  ## `patches` are recipe-relative `-p1` unified diffs applied in order to
  ## the build's copy of the source (see the module docstring).
  if target.len == 0 or not target.startsWith("exe:") or target.len <= 4:
    raise newException(ValueError,
      "cabal_package: `target` must name an executable as `exe:<name>`, " &
      "got \"" & target & "\"")
  let exeName = target[4 .. ^1]
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()

  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw
    elif srcDir.len > 0: srcDir
    else: "src"

  let fetchOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  let plan =
    if projectRoot.len > 0: readHackageVendorManifest(projectRoot)
    else: @[]
  var vendorEdge = BuildActionDef()
  if projectRoot.len > 0:
    vendorEdge = emitHackageVendorAction(projectRoot, pkgName, plan,
      (if fetchOpt.isSome: fetchOpt.get().id else: ""),
      (if fetchOpt.isSome and fetchOpt.get().outputs.len > 0:
         fetchOpt.get().outputs[0]
       else: ""))

  let root = (if projectRoot.len > 0: projectRoot else: ".")
  let src = root / extractedRel
  let work = cabalWorkDir(root)
  let buildDir = cabalBuildDir(root)
  let cabalDir = hackageCabalDir(root)
  let effectiveDestdir =
    if destdir.len > 0: destdir
    else: cabalDestdir(root)

  proc q(v: string): string = v.replace("\\", "/").replace("\"", "\\\"")

  var envPrefix = "export CABAL_DIR=\"" & q(cabalDir) & "\"; "
  for (k, v) in extraEnv:
    envPrefix.add("export " & k & "=\"" & q(v) & "\"; ")
  let cabalFlags = " --builddir=\"" & q(buildDir) & "\""

  var patchInputs: seq[string] = @[]
  var buildScript = "set -e; " & envPrefix
  buildScript.add("rm -rf \"" & q(work) & "\"; ")
  buildScript.add("mkdir -p \"" & q(work) & "\"; ")
  buildScript.add("cp -R \"" & q(src) & "/.\" \"" & q(work) & "/\"; ")
  buildScript.add("cd \"" & q(work) & "\"; ")
  for patch in patches:
    let patchPath =
      if patch.isAbsolute: patch
      else: root / patch
    patchInputs.add(patchPath)
    buildScript.add("GIT_CEILING_DIRECTORIES=\"" & q(parentDir(work)) &
      "\" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null " &
      "git apply -p1 --whitespace=nowarn \"" & q(patchPath) & "\"; ")
  buildScript.add("cabal build " & target & cabalFlags & "; ")

  var compileInputs: seq[string] = @[]
  if vendorEdge.outputs.len > 0:
    compileInputs.add(vendorEdge.outputs[0])
  compileInputs.add(patchInputs)
  let compileEdge = buildAction(
    id = "cabal-build-" & pkgName,
    call = inlineExecCall(@["sh", "-c", buildScript], root),
    deps = (if vendorEdge.id.len > 0: @[vendorEdge.id] else: @[]),
    inputs = compileInputs,
    outputs = @[],
    declaredOutputs = @[buildDir],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cabal_package.build",
    toolIdentityRefs = @["sh", "rm", "mkdir", "cp", "git", "cabal", "ghc"])

  let binDir = effectiveDestdir / "usr" / "bin"
  var installScript = "set -e; " & envPrefix
  installScript.add("cd \"" & q(work) & "\"; ")
  installScript.add("repro_bin=\"$(cabal list-bin " & target & cabalFlags &
    ")\"; ")
  installScript.add("rm -rf \"" & q(effectiveDestdir) & "\"; ")
  installScript.add("mkdir -p \"" & q(binDir) & "\"; ")
  # Take the file whether or not `list-bin` spelled out the `.exe`.
  let installedName = exeName & (when defined(windows): ".exe" else: "")
  installScript.add("if [ ! -f \"$repro_bin\" ] && [ -f \"$repro_bin.exe\" ]; " &
    "then repro_bin=\"$repro_bin.exe\"; fi; ")
  installScript.add("cp -f \"$repro_bin\" \"" & q(binDir) & "/" &
    installedName & "\"; ")
  let installEdge = buildAction(
    id = "cabal-install-" & pkgName,
    call = inlineExecCall(@["sh", "-c", installScript], root),
    deps = @[compileEdge.id],
    inputs = @[],
    outputs = @[effectiveDestdir],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cabal_package.install",
    toolIdentityRefs = @["sh", "rm", "mkdir", "cp", "cabal", "ghc"])

  CabalPackageResult(
    buildEdge: vendorEdge,
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
