## `cargo_package(...)` — the `build:`-block pipeline for a from-source
## Rust recipe.
##
## Sibling of `autotools_package` / `cmake_package` / `meson_package`, and
## the piece that lets a recipe say what it builds instead of how to acquire
## it. Internally: fetch → vendor → `cargo build` → `cargo install`.
##
## ## What is different from the other three
##
## Cargo has no configure phase, but a from-source cargo recipe does have a
## preparation phase that must finish before a compile can start offline:
## the one that materialises the locked dependency closure. That step takes
## the `buildEdge` slot, so the ordering is explicit to anything walking the
## result's three edges rather than hidden behind a stamp the result never
## mentions.
##
## The closure itself comes from the recipe's committed
## `cargo-vendor.manifest` (see `repro_core/cargo_lock` for why it is
## committed rather than derived at build time, and
## `repro_project_dsl/cargo_vendor` for the action). This constructor and
## the `from-source-cargo` convention emit that step under the same action
## id, so the engine coalesces them instead of vendoring twice.
##
## ## Why `cargo install` rather than a copy out of `target/`
##
## `cargo install --root <dir>` writes `<dir>/bin/<binary>`, which is
## already the shape `standardComponents()` describes. Copying out of
## `target/<profile>/` would mean guessing which of that directory's many
## files are the package's binaries; cargo knows, from the manifest. The
## install shares `--target-dir` with the build, so it reuses artefacts
## rather than compiling a second time.
##
## ## `--offline` is the point
##
## Both cargo steps pass `--locked --offline`. Offline is what a from-source
## build is FOR: the closure is already vendored, so a crate the manifest
## missed must fail here rather than be quietly downloaded. `--locked` is
## the companion — it refuses to update `Cargo.lock`, so the build cannot
## silently resolve something other than what was pinned.

import std/[options, os, strutils]

import repro_project_dsl
import repro_project_dsl/cargo_vendor

import ../types/package_result
import ../packages/cargo as cargo_module

const
  FetchScratchSubdir = ".repro/fetch"
    ## Where the source tarball and its stamp land. The same literal each
    ## sibling constructor declares privately, and deliberately the same
    ## VALUE: the convention's own fetch emitter writes there too, so a
    ## divergence here would mean two downloads of one tarball.

  CargoScratchSubdir* = ".repro/build/cargo"
    ## Scratch root for the compile. `--target-dir` points here rather
    ## than at the extracted source, so the source tree stays read-only
    ## and a `repro clean` takes the build products with everything else
    ## under `.repro/`.

proc cargoTargetDir*(projectRoot: string): string =
  projectRoot / CargoScratchSubdir / "target"

proc cargoDestdir*(projectRoot: string): string =
  ## DESTDIR-style staging root. `cargo install --root <this>/usr` lands
  ## binaries at `<this>/usr/bin`, matching the `runtime` component.
  projectRoot / CargoScratchSubdir / "out"

proc cargoFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "cargo-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  ## Emit the source fetch when the recipe declared one.
  ##
  ## Same shape as the sibling constructors' own helpers, including the
  ## `file:./` relative form, so a recipe that vendors its source tarball
  ## can reference it without baking a host path into the recipe.
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
    id = cargoFetchActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    # Non-cacheable for the reason every source fetch is: it reaches the
    # network and has no monitorable file-dependency evidence.
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cargo_package.fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = fetchToolRefs))

proc cargo_package*(srcDir = "src";
                    destdir = "";
                    profile = "release";
                    features: seq[string] = @[];
                    noDefaultFeatures = false;
                    extraEnv: seq[(string, string)] = @[]):
    CargoPackageResult =
  ## Fetch → vendor → build → install, for an upstream crate.
  ##
  ## `srcDir` is where the fetch extracted the source; it defaults to the
  ## `src` that `fetch:` uses when the recipe does not name an
  ## `extractedRoot`.
  ##
  ## `profile` selects cargo's profile. A from-source package is a release
  ## artefact, so `release` is the default; any other value is passed
  ## through for a recipe that has defined its own profile.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()

  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw
    elif srcDir.len > 0: srcDir
    else: "src"

  let fetchOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)

  # The vendored closure. Read at emission time so the manifest's content
  # reaches the action fingerprint, and refused by name when it is absent:
  # a from-source Rust recipe without a pinned closure is one that builds
  # on the machine with a warm registry cache and nowhere else.
  let plan =
    if projectRoot.len > 0: readVendorManifest(projectRoot)
    else: @[]
  var vendorEdge = BuildActionDef()
  if projectRoot.len > 0:
    vendorEdge = emitCargoVendorAction(projectRoot, pkgName, plan,
      (if fetchOpt.isSome: fetchOpt.get().id else: ""),
      (if fetchOpt.isSome and fetchOpt.get().outputs.len > 0:
         fetchOpt.get().outputs[0]
       else: ""))

  let manifestPath = extractedRel / "Cargo.toml"
  let targetDir =
    if projectRoot.len > 0: cargoTargetDir(projectRoot)
    else: CargoScratchSubdir / "target"
  let effectiveDestdir =
    if destdir.len > 0: destdir
    elif projectRoot.len > 0: cargoDestdir(projectRoot)
    else: CargoScratchSubdir / "out"
  let featureList = features.join(",")
  let releaseProfile = profile == "release"

  var compileEdge = cargo_module.cargo.build(
    locked = true,
    release = releaseProfile,
    offline = true,
    noDefaultFeatures = noDefaultFeatures,
    features = featureList,
    manifestPath = manifestPath,
    targetDir = targetDir,
    after = (if vendorEdge.id.len > 0: @[vendorEdge] else: @[]),
    extraEnv = extraEnv)

  # The source tree is an INPUT, not a write target: cargo writes into
  # `--target-dir`, and a recipe whose build mutated the extracted source
  # would produce a different tree on a second run from the same tarball.
  if projectRoot.len > 0:
    let srcAbs = projectRoot / extractedRel
    setRegisteredActionDeclaredOutputs(compileEdge.id, @[targetDir])
    setRegisteredActionReadOnlyRoots(compileEdge.id, @[srcAbs])
    setRegisteredActionDependencyPolicy(compileEdge.id,
      automaticMonitorPolicy(@[targetDir]))

  # `--root <destdir>/usr` so binaries land at `<destdir>/usr/bin`, the
  # `runtime` component's path. Ordered after the compile and sharing its
  # target directory, so this places artefacts rather than rebuilding them.
  let installRoot = effectiveDestdir / "usr"
  let installEdge = cargo_module.cargo.install(
    locked = true,
    offline = true,
    # Without `--no-track`, cargo writes a `.crates.toml` ledger into the
    # root recording what it installed there. That is per-install state
    # about a directory this build owns outright, and it makes the staged
    # tree differ between a first run and a re-run.
    noTrack = true,
    noDefaultFeatures = noDefaultFeatures,
    features = featureList,
    path = extractedRel,
    root = installRoot,
    targetDir = targetDir,
    after = @[compileEdge],
    extraEnv = extraEnv)
  if projectRoot.len > 0:
    setRegisteredActionDeclaredOutputs(installEdge.id, @[effectiveDestdir])
    setRegisteredActionReadOnlyRoots(installEdge.id,
      @[projectRoot / extractedRel])

  CargoPackageResult(
    buildEdge: vendorEdge,
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
