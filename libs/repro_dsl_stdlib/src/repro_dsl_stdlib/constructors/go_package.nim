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
## different bytes under two different scratch roots. `-trimpath` misses
## assembly files `#include`d across directories, so the build runs the
## assembler through a small `-toolexec` wrapper that adds the module cache
## to its rewrites (`goAsmTrimpathWrapper`), with a per-recipe `GOCACHE`
## so no object assembled without it is reused.
##
## ## Several commands from one module
##
## `extraBinaries` names further `(binaryName, mainPackage)` pairs that the
## same build edge compiles into the same destdir, one `go build -o` each.
## A module that ships a node, a client and a tool from one `go.sum` is one
## download and one closure, so splitting it over several recipes would
## fetch and verify the same modules once per command.
##
## ## Static cgo
##
## Some modules cannot be built without cgo: they bind a C library that
## has no Go implementation (BLS signatures, KZG commitments). A cgo build
## against the host's C toolchain links the host's libc dynamically, so
## the result runs only where that libc is. `staticCgo = true` instead
## makes zig the C compiler and linker, targeting the host architecture's
## musl, and asks Go for a fully static executable:
##
##   * `CC` / `CXX` are the wrappers of `adapters/cross_zig` for the
##     musl triple of the host CPU (one wrapper implementation in the
##     tree, not one per constructor);
##   * `-tags netgo,osusergo` select Go's own DNS resolver and user lookup,
##     which a static musl binary needs because there is no NSS to load
##     (https://pkg.go.dev/net#hdr-Name_Resolution, https://pkg.go.dev/os/user);
##   * `-ldflags "-linkmode external -extldflags '-static -Wl,--strip-debug'"`
##     hands the final link to zig, static and without the debug sections
##     that would carry the checkout's path (https://pkg.go.dev/cmd/link).
##
## Zig keeps a compilation cache; its global and local caches are pointed
## under this recipe's scratch tree so the build neither reads nor writes
## the user's home.

import std/[options, os, strutils]

import repro_project_dsl

import ../types/package_result
import ../active_context
import ../adapters/cross_zig

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

proc goZigCacheDir*(projectRoot: string): string =
  ## Root of zig's global and local caches for a `staticCgo` build. Under
  ## the recipe's scratch tree, so `repro clean` takes it and the build
  ## never touches `$HOME/.cache/zig`.
  projectRoot / GoScratchSubdir / "zig-cache"

proc goStaticCgoTriple*(cpu = hostCPU): string =
  ## The musl triple a `staticCgo` build targets: the row of
  ## `ZigCrossTargets` for the CPU Go compiles for (Go's default `GOARCH`
  ## is the host's, and the C half must match it). A CPU without a row is
  ## refused by name rather than linked for the wrong architecture.
  for t in ZigCrossTargets:
    if t.nimCpu == cpu and t.rustTriple.endsWith("-linux-musl"):
      return t.rustTriple
  raise newException(ValueError,
    "go_package: staticCgo has no zig musl target for the CPU '" & cpu &
    "'; add a row to cross_zig.ZigCrossTargets.")

const
  GoStaticCgoTags* = ["netgo", "osusergo"]
    ## Go's own resolver and user lookup: a static musl binary has no NSS.
  GoStaticCgoLdflags* =
    "-linkmode external -extldflags '-static -Wl,--strip-debug'"
    ## The final link goes to the external linker (zig), told `-static`,
    ## and to drop debug sections: zig compiles musl, compiler-rt and the
    ## cgo C sources with DWARF whose `DW_AT_comp_dir` and file names are
    ## the recipe's scratch tree and zig's install path, so with the
    ## sections kept the bytes depend on the checkout's path (measured:
    ## prysm from two checkouts differed only in `.debug_*`). The Go
    ## linker's own `-s -w` do not reach the external link.

const GoAsmTrimVar* = "REPRO_GO_ASM_TRIMPATH"
  ## Environment variable naming the module cache root, which the
  ## `-toolexec` wrapper appends to the assembler's `-trimpath` rewrites.

proc goCacheDir*(projectRoot: string): string =
  ## `GOCACHE` for this recipe. Per recipe for the reason `GOMODCACHE` is,
  ## and because Go's build cache does not key an object on the
  ## environment a `-toolexec` wrapper reads: an object assembled before
  ## the wrapper existed (or for another checkout) would otherwise be
  ## reused with its absolute paths still in it.
  projectRoot / GoScratchSubdir / "cache"

proc goAsmTrimpathWrapperPath*(projectRoot: string): string =
  projectRoot / GoScratchSubdir / "toolexec" / "asm-trimpath"

proc goAsmTrimpathWrapper*(): string =
  ## The `go build -toolexec` program that completes `-trimpath` for
  ## assembly. `-trimpath` hands the assembler one rewrite per package, its
  ## own directory; a `.s` file `#include`d from ANOTHER directory keeps its
  ## absolute path in the binary's line table (gnark-crypto's
  ## `field/asm/*.s`, included by its curve packages, put the module
  ## cache's absolute path into geth and prysm). The wrapper appends the
  ## module cache root (`$REPRO_GO_ASM_TRIMPATH`) as one more rewrite, so
  ## such a file reads `<module>@<version>/...` as the package's own files
  ## do; Go's rewrites stay first and win for every file they cover. Every
  ## other tool runs unchanged. Contains no single quote: the build script
  ## writes it with `printf '%s' '<text>'`.
  ## https://pkg.go.dev/cmd/go#hdr-Compile_packages_and_dependencies
  ## (`-toolexec`), https://pkg.go.dev/cmd/asm (`-trimpath`).
  "#!/bin/sh\n" &
  "tool=$1\n" &
  "shift\n" &
  "case ${tool##*/} in\n" &
  "  asm|asm.exe) ;;\n" &
  "  *) exec \"$tool\" \"$@\" ;;\n" &
  "esac\n" &
  "next=\n" &
  "for a do\n" &
  "  shift\n" &
  "  if [ \"$next\" = 1 ]; then a=\"$a;$" & GoAsmTrimVar & "\"; fi\n" &
  "  next=\n" &
  "  if [ \"$a\" = -trimpath ]; then next=1; fi\n" &
  "  set -- \"$@\" \"$a\"\n" &
  "done\n" &
  "exec \"$tool\" \"$@\"\n"

proc goMergedTags*(tags: seq[string]; staticCgo: bool): seq[string] =
  ## The recipe's tags, followed by the static-cgo tags it did not already
  ## name. Order is kept so a recipe's own list renders as before.
  result = tags
  if staticCgo:
    for t in GoStaticCgoTags:
      if t notin result:
        result.add(t)

proc goMergedLdflags*(ldflags: string; staticCgo: bool): string =
  ## The recipe's ldflags, followed by the static-cgo link flags.
  if not staticCgo:
    return ldflags
  if ldflags.len == 0:
    return GoStaticCgoLdflags
  ldflags & " " & GoStaticCgoLdflags

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
                 extraEnv: seq[(string, string)] = @[];
                 extraBinaries: seq[(string, string)] = @[];
                 staticCgo = false): GoPackageResult =
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
  ##
  ## `extraBinaries` are further `(binaryName, mainPackage)` pairs built by
  ## the same edge into the same `usr/bin`. `staticCgo` builds a static
  ## cgo executable with zig as the C toolchain (see the module header);
  ## the recipe must declare `zig` in `nativeBuildDeps`. Both default to
  ## off, and with both off the emitted actions are unchanged.
  requireCrossTargetConsulted("go_package")
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

  let binDir = effectiveDestdir / "usr" / "bin"
  let outputPath = binDir / binaryName
  for (name, _) in extraBinaries:
    if name.len == 0 or name == binaryName or '/' in name:
      raise newException(ValueError,
        "go_package: extraBinaries name '" & name & "' must be a plain " &
        "file name distinct from binaryName '" & binaryName & "'")
  var outputs = @[outputPath]
  for (name, _) in extraBinaries:
    let path = binDir / name
    if path in outputs:
      raise newException(ValueError,
        "go_package: extraBinaries names '" & name & "' twice")
    outputs.add(path)

  # Static cgo: zig, through the cross adapter's wrappers, is the C
  # compiler and the external linker; its caches live in scratch.
  var buildDeps = @[downloadEdge.id]
  var buildInputs = @[downloadStamp]
  var buildToolRefs = @["sh", "mkdir", "printf", "chmod", "go"]
  let goCache =
    if projectRoot.len > 0: goCacheDir(projectRoot)
    else: GoScratchSubdir / "cache"
  let asmWrapper =
    if projectRoot.len > 0: goAsmTrimpathWrapperPath(projectRoot)
    else: GoScratchSubdir / "toolexec" / "asm-trimpath"
  var ignoredRoots = @[effectiveDestdir, modCache, goCache,
                       parentDir(asmWrapper)]
  var cgoEnv = ""
  if staticCgo:
    let triple = goStaticCgoTriple()
    let root = if projectRoot.len > 0: projectRoot else: "."
    let wrapperDir = zigCrossWrapperDir(root, triple)
    let zigCache =
      if projectRoot.len > 0: goZigCacheDir(projectRoot)
      else: GoScratchSubdir / "zig-cache"
    cgoEnv.add("CC=\"" & q(wrapperDir / "cc") & "\" ")
    cgoEnv.add("CXX=\"" & q(wrapperDir / "c++") & "\" ")
    cgoEnv.add("ZIG_GLOBAL_CACHE_DIR=\"" & q(zigCache / "global") & "\" ")
    cgoEnv.add("ZIG_LOCAL_CACHE_DIR=\"" & q(zigCache / "local") & "\" ")
    buildToolRefs.add("zig")
    ignoredRoots.add(zigCache)
    if projectRoot.len > 0:
      let wrappers = emitZigCrossWrappersAction(projectRoot, pkgName, triple)
      buildDeps.add(wrappers.id)
      buildInputs.add(wrappers.outputs)

  let effectiveTags = goMergedTags(tags, staticCgo)
  let effectiveLdflags = goMergedLdflags(ldflags, staticCgo)

  proc goBuildCommand(output, pkg: string): string =
    # GOPROXY=off is what makes this offline: a module the download step
    # did not fetch is a hard error here rather than a quiet network call.
    result = "GOMODCACHE=\"" & q(modCache) & "\" "
    result.add("GOCACHE=\"" & q(goCache) & "\" ")
    result.add(GoAsmTrimVar & "=\"" & q(modCache) & "\" ")
    result.add("GOPROXY=off GOFLAGS=-mod=mod ")
    result.add("CGO_ENABLED=" & (if cgo or staticCgo: "1" else: "0") & " ")
    result.add(cgoEnv)
    result.add("go build ")
    # -trimpath because a Go binary otherwise embeds the absolute path of
    # its build directory, and the same source would produce different
    # bytes under two different scratch roots.
    result.add("-trimpath ")
    # The wrapper that completes -trimpath for assembly (see
    # `goAsmTrimpathWrapper`). Not a build flag: `go build` records
    # `-asmflags` in the binary's build information, and the value would
    # carry the very path being removed; `-toolexec` is not recorded.
    result.add("-toolexec \"" & q(asmWrapper) & "\" ")
    if effectiveTags.len > 0:
      result.add("-tags \"" & q(effectiveTags.join(",")) & "\" ")
    if effectiveLdflags.len > 0:
      result.add("-ldflags \"" & q(effectiveLdflags) & "\" ")
    result.add("-o \"" & q(output) & "\" ")
    result.add("\"" & q(pkg) & "\"")

  var buildScript = "set -e; "
  buildScript.add("mkdir -p \"" & q(binDir) & "\"; ")
  buildScript.add("cd \"" & q(srcAbs) & "\"; ")
  buildScript.add("mkdir -p \"" & q(parentDir(asmWrapper)) & "\"; ")
  buildScript.add("printf '%s' '" & goAsmTrimpathWrapper() & "' > \"" &
    q(asmWrapper) & "\"; chmod 755 \"" & q(asmWrapper) & "\"; ")
  buildScript.add(goBuildCommand(outputPath, mainPackage))
  for (name, pkg) in extraBinaries:
    buildScript.add("; " & goBuildCommand(binDir / name, pkg))

  let buildEdge = buildAction(
    id = "go-build-" & goActionIdPart(pkgName),
    call = inlineExecCall(@["sh", "-c", buildScript], projectRoot),
    deps = buildDeps,
    inputs = buildInputs,
    outputs = outputs,
    pool = "compile",
    # ``effectiveDestdir`` is also this edge's declared write ROOT below, so
    # the engine DERIVES the enumeration ignore for it
    # (``repro_build_engine.enumerationIgnoredRoots``) and the entry here is
    # redundant for that channel. It is kept, and this is why: the write-root
    # declaration below is guarded on ``projectRoot.len > 0`` while this
    # policy is not, so without a project root there is nothing to derive
    # from and this entry is the only ignore the edge has. Unlike the other
    # eight duplicate entries in the tree, this one is NOT load-bearing for
    # the read channel -- ``go build -o`` writes the destdir and does not
    # read it back -- so the asymmetric guard is the whole reason it stays.
    # ``modCache`` is a genuine exception: read back on every run and not a
    # declared output of anything, and so are the Go build cache, the
    # assembler wrapper the edge writes, and zig's cache under `staticCgo`.
    dependencyPolicy = automaticMonitorPolicy(ignoredRoots),
    commandStatsId = "go_package.build",
    toolIdentityRefs = buildToolRefs)
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
