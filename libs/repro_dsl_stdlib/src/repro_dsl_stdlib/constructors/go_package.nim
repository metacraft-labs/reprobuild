## `go_package(...)` — the `build:`-block pipeline for a from-source Go
## recipe.
##
## Sibling of `cargo_package`, covering the Go half of the same tool tier:
## `shfmt` and `addlicense` among Agent Harbor's pinned CLIs. Internally:
## fetch → `go mod download` → `go build`.
##
## ## How the closure is pinned, and why it differs from cargo
##
## Both shapes need the dependency closure on disk before an offline build,
## and both take it from a pinned, hash-carrying file inside the fetched
## source. The difference is who verifies.
##
## Cargo's `Cargo.lock` records a plain SHA-256 per crate archive, so this
## repository can read it, commit the resulting plan, and verify each
## download with `sha256sum` — no toolchain involved, and the closure is
## visible in the tree.
##
## Go's `go.sum` records `h1:` dirhashes: SHA-256 over a sorted listing of
## the module's files, not over the archive that carries them. Verifying one
## outside the toolchain means reimplementing Go's `dirhash`, and a
## reimplementation that drifted would either reject good modules or accept
## bad ones. So the Go shape runs `go mod download`, which verifies every
## module against the `go.sum` in the fetched source and populates a scratch
## module cache. Same guarantee, reached through the tool that defines it.
##
## The cost is honest and worth naming: the Go closure is not visible in
## this repository the way the cargo one is. What is pinned here is the
## source digest; what pins the closure is the `go.sum` inside it.
##
## ## What makes the build offline
##
## `GOFLAGS=-mod=mod` with `GOPROXY=off` and `GOMODCACHE` pointed at the
## cache the download step filled. With the proxy off, a module the
## download step did not fetch is a hard error rather than a silent
## network call — which is the property the from-source tier exists to
## have.
##
## `-trimpath` is passed because a Go binary otherwise embeds the absolute
## path of its build directory, which would make the same source produce
## different bytes under two different scratch roots.

import std/[options, os, strutils]

import repro_project_dsl

import ../types/package_result

const
  FetchScratchSubdir = ".repro/fetch"
    ## Where the source tarball and its stamp land — the same value each
    ## sibling constructor uses, so a recipe's source is fetched once
    ## however many emitters ask for it.

  GoScratchSubdir* = ".repro/build/go"
    ## Scratch root for the module cache and the staged output. Under
    ## `.repro/` so a `repro clean` takes both.

proc goModCacheDir*(projectRoot: string): string =
  ## `GOMODCACHE` for this recipe.
  ##
  ## Per-recipe rather than the user's `~/go/pkg/mod`: a build that read
  ## the ambient cache would succeed on a machine that happened to have a
  ## module warm and fail on one that did not, which is the failure the
  ## whole tier removes.
  projectRoot / GoScratchSubdir / "modcache"

proc goDestdir*(projectRoot: string): string =
  ## DESTDIR-style staging root. `go build -o <this>/usr/bin/<name>` lands
  ## the binary at the `runtime` component's path.
  projectRoot / GoScratchSubdir / "out"

proc goModDownloadStampPath*(projectRoot: string): string =
  projectRoot / GoScratchSubdir / "mod-download.stamp"

proc goActionIdPart(packageName: string): string =
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  ## Emit the source fetch when the recipe declared one. Same shape as the
  ## sibling constructors', including the `file:./` relative form.
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
    id = "go-fetch-" & goActionIdPart(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go_package.fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = fetchToolRefs))

proc go_package*(binaryName: string;
                 srcDir = "src";
                 destdir = "";
                 mainPackage = ".";
                 ldflags = "";
                 tags: seq[string] = @[];
                 cgo = false;
                 extraEnv: seq[(string, string)] = @[]): GoPackageResult =
  ## Fetch → module download → build, for an upstream Go module.
  ##
  ## `binaryName` is required, unlike the cargo shape: `go build -o` names
  ## its output explicitly, and there is no manifest for the constructor to
  ## learn the name from the way `cargo install` reads one.
  ##
  ## `mainPackage` is the package path to build, relative to the module
  ## root — `"."` for a module whose main package is at its root, or
  ## `"./cmd/<name>"` for the common multi-command layout.
  ##
  ## `cgo` defaults to off. Every tool in this tier is pure Go, and a
  ## CGO-enabled build would silently acquire a dependency on whatever C
  ## toolchain and system headers the host happens to have — which is a
  ## dependency the recipe has not declared.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()

  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw
    elif srcDir.len > 0: srcDir
    else: "src"

  let fetchOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)

  let srcAbs =
    if projectRoot.len > 0: projectRoot / extractedRel else: extractedRel
  let modCache =
    if projectRoot.len > 0: goModCacheDir(projectRoot)
    else: GoScratchSubdir / "modcache"
  let effectiveDestdir =
    if destdir.len > 0: destdir
    elif projectRoot.len > 0: goDestdir(projectRoot)
    else: GoScratchSubdir / "out"
  let downloadStamp =
    if projectRoot.len > 0: goModDownloadStampPath(projectRoot)
    else: GoScratchSubdir / "mod-download.stamp"

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  # The module cache is not shared with the host's, and it is writable by
  # the module cache's own rules (read-only directories), so a rebuild has
  # to be able to clear it. `go clean -modcache` would need the toolchain;
  # `chmod -R u+w` then `rm -rf` is what works before one is guaranteed.
  var downloadScript = "set -e; "
  downloadScript.add("mkdir -p \"" & q(modCache) & "\"; ")
  downloadScript.add("cd \"" & q(srcAbs) & "\"; ")
  # `go mod download` is the verification step: every module is checked
  # against the `go.sum` in this source tree. It is also the ONLY step
  # allowed to reach the network, which is why the proxy is left at its
  # default here and turned off for the build below.
  downloadScript.add("GOMODCACHE=\"" & q(modCache) & "\" " &
    "GOFLAGS=-mod=mod go mod download all; ")
  downloadScript.add("mkdir -p \"" & q(parentDir(downloadStamp)) & "\"; ")
  downloadScript.add(": > \"" & q(downloadStamp) & "\"")

  var downloadDeps: seq[string] = @[]
  var downloadInputs: seq[string] = @[]
  if fetchOpt.isSome:
    downloadDeps.add(fetchOpt.get().id)
    downloadInputs.add(fetchOpt.get().outputs)

  let downloadEdge = buildAction(
    id = "go-mod-download-" & goActionIdPart(pkgName),
    call = inlineExecCall(@["sh", "-c", downloadScript], projectRoot),
    deps = downloadDeps,
    inputs = downloadInputs,
    outputs = @[downloadStamp],
    pool = "fetch",
    # Non-cacheable for the reason every acquisition step is: it reaches
    # the network and has no monitorable file-dependency evidence. The
    # stamp short-circuits it on a second run.
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(@[modCache]),
    commandStatsId = "go_package.mod_download",
    toolIdentityRefs = @["sh", "mkdir", "go"])

  let outputPath = effectiveDestdir / "usr" / "bin" / binaryName
  var buildScript = "set -e; "
  buildScript.add("mkdir -p \"" & q(parentDir(outputPath)) & "\"; ")
  buildScript.add("cd \"" & q(srcAbs) & "\"; ")
  # GOPROXY=off is what makes this offline: a module the download step did
  # not fetch is a hard error here rather than a quiet network call.
  buildScript.add("GOMODCACHE=\"" & q(modCache) & "\" ")
  buildScript.add("GOPROXY=off GOFLAGS=-mod=mod ")
  buildScript.add("CGO_ENABLED=" & (if cgo: "1" else: "0") & " ")
  buildScript.add("go build ")
  # -trimpath because a Go binary otherwise embeds the absolute path of
  # its build directory, and the same source would produce different bytes
  # under two different scratch roots.
  buildScript.add("-trimpath ")
  if tags.len > 0:
    buildScript.add("-tags \"" & q(tags.join(",")) & "\" ")
  if ldflags.len > 0:
    buildScript.add("-ldflags \"" & q(ldflags) & "\" ")
  buildScript.add("-o \"" & q(outputPath) & "\" ")
  buildScript.add("\"" & q(mainPackage) & "\"")

  let buildEdge = buildAction(
    id = "go-build-" & goActionIdPart(pkgName),
    call = inlineExecCall(@["sh", "-c", buildScript], projectRoot),
    deps = @[downloadEdge.id],
    inputs = @[downloadStamp],
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(@[effectiveDestdir, modCache]),
    commandStatsId = "go_package.build",
    toolIdentityRefs = @["sh", "mkdir", "go"])
  if projectRoot.len > 0:
    setRegisteredActionDeclaredOutputs(buildEdge.id, @[effectiveDestdir])
    # The source stays read-only: a build that wrote into its own
    # extracted tree would produce a different tree on a second run from
    # the same tarball.
    setRegisteredActionReadOnlyRoots(buildEdge.id, @[srcAbs])

  GoPackageResult(
    buildEdge: downloadEdge,
    # One action in both slots. `go build -o` writes straight into the
    # staged tree, so there is no install step to model; inventing a second
    # action would only copy a file onto itself.
    compileEdge: buildEdge,
    installEdge: buildEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
