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
##
## ## Cross-compiling, and workspace members
##
## The target comes from the active build context: `repro build
## --target=<triple>` resolves the `targetTriple` variant, the context's
## `crossTarget` slot is filled by the adapter that claims the triple
## (`active_context.resolveCrossTarget`), and this constructor reads it
## (`activeCrossTarget()`). Both cargo steps then carry `--target`, and when
## the adapter is `adapters/cross_zig`'s, zig is the target's C toolchain and
## linker: a wrapper-writing edge is emitted and the cargo edges get the
## `CC_<triple>` / `CARGO_TARGET_<TRIPLE>_*` environment that points at it.
## The recipe spells none of this, so the same recipe builds natively and
## for every listed target.
##
## `target` and `zigCross` remain as EXPLICIT overrides for a recipe that is
## only ever a cross build (a service for one appliance) or that brings its
## own C toolchain in `extraEnv`. An explicit `target` that contradicts the
## active cross target is refused: the two would otherwise produce an
## artefact for one platform under a cache identity stamped for another.
## The target's standard library has to be in rustc's sysroot
## (`lib/rustlib/<triple>/`), and the catalog's `rustc` carries only the
## host's: for a cross target this constructor emits the two edges of
## `adapters/rust_target_sysroot` -- a fetch of the catalog's `rust-std`
## component for the triple and a merge of it into a copy of the host
## `rustc` prefix -- and points the cargo edges at the result with `RUSTC`.
## A recipe that sets `RUSTC` in `extraEnv` brings its own sysroot and the
## edges are not emitted; a target the catalog has no component for is
## refused by name.
##
## `package` selects one member of a virtual workspace (`cargo build -p`),
## and `installPath` is that member's directory within the source tree
## (`cargo install --path <src>/<installPath>`): a workspace root has no
## `[package]`, so `cargo install --path <src>` on it fails.
## Language-Conventions/Rust.md §"Cross-compiling".

import std/[options, os, strutils]

import repro_project_dsl
import repro_project_dsl/cargo_vendor

import ../types/package_result
import ../packages/cargo as cargo_module
import ../adapters/cross_zig
import ../adapters/rust_target_sysroot
import ../active_context

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
  var fetchToolRefs = shellFetchToolIdentityRefs(hashTools,
    copiesDataFile = spec.kind == dfkDataFile,
    archiveUrl = resolvedUrl)
  if spec.kind == dfkGitArchive:
    # `ssh` as well as `git`: a private repository is reached over ssh (an
    # https remote would need a credential helper, which is not a tool the
    # edge can declare), and git execs `ssh` from the edge's PATH.
    fetchToolRefs.add("git")
    fetchToolRefs.add("ssh")
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  let staged = extracted & ".repro-extract-" & spec.hashHex
  let escapedStaged = staged.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("rm -rf \"" & escapedStaged & "\"; ")
  script.add("mkdir -p \"" & escapedStaged & "\"; ")
  case spec.kind
  of dfkGitArchive:
    # A repository source (a private one has no archive URL): acquired as
    # `git archive` of the pinned revision, by the shared script, and
    # verified like any tarball below.
    script.add(gitArchiveFetchScript(
      resolvedUrl.replace("\"", "\\\""), spec.gitRevision.replace("\"", "\\\""),
      escapedTarball))
  else:
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
                    extraEnv: seq[(string, string)] = @[];
                    target = "";
                    zigCross = false;
                    package = "";
                    installPath = ""):
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

  # The target: the active cross target's triple unless the recipe named
  # one, and the two must agree when both are present (see the header).
  # `zigCross` follows the adapter that filled the slot; a recipe may still
  # say `zigCross = true` with an explicit `target` and no active one.
  let active = peekActiveCrossTarget()
  let activeTriple = active.tripleOrEmpty()
  var target = target
  var zigCross = zigCross
  if activeTriple.len > 0:
    if target.len > 0 and target != activeTriple:
      raise newException(ValueError,
        "cargo_package: the recipe names target '" & target &
        "' but the build's targetTriple is '" & activeTriple &
        "'; drop the recipe's target or build with --target=" & target)
    target = activeTriple
    if isZigCrossTarget(active):
      zigCross = true

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

  # The cross C toolchain. Its wrappers are written by their own edge, and
  # the environment below is what makes cargo, rustc and the `cc` crate use
  # them; `zigCross` without a `target` is a contradiction and is refused.
  if zigCross and target.len == 0:
    raise newException(ValueError,
      "cargo_package: zigCross = true needs a target triple")
  var env = extraEnv
  var compileAfter: seq[BuildActionDef] = @[]
  if vendorEdge.id.len > 0:
    compileAfter.add(vendorEdge)
  if zigCross:
    let wrapperDir = zigCrossWrapperDir(
      (if projectRoot.len > 0: projectRoot else: "."), target)
    env.add(zigCrossCargoEnv(target, wrapperDir, remapRoot = projectRoot))
    if projectRoot.len > 0:
      compileAfter.add(emitZigCrossWrappersAction(projectRoot, pkgName,
        target))

  # The target's standard library (see the header). A `RUSTC` the recipe
  # set itself is its own sysroot and wins; otherwise the catalog must have
  # the component, and the merged prefix is what cargo drives.
  if target.len > 0:
    var recipeRustc = false
    for (k, _) in env:
      if k == "RUSTC": recipeRustc = true
    if not recipeRustc:
      discard rustStdComponent(target)   # refuses an uncatalogued target
      let root = if projectRoot.len > 0: projectRoot else: "."
      env.add(("RUSTC", rustTargetRustcPath(root, target)))
      if projectRoot.len > 0:
        let fetch = emitRustStdFetchAction(projectRoot, pkgName, target)
        compileAfter.add(emitRustTargetSysrootAction(projectRoot, pkgName,
          target, fetch))

  # The vendored-sources configuration the vendor action writes beside the
  # extracted source, named explicitly: cargo runs from the recipe root and
  # reads configuration from its working directory upward, not from the
  # manifest's, so the file would otherwise never be read and an offline
  # build would refuse its first crate.
  let vendoredConfig =
    if projectRoot.len > 0: cargoConfigDir(projectRoot) / "config.toml"
    else: ""
  var compileEdge = cargo_module.cargo.build(
    config = vendoredConfig,
    locked = true,
    release = releaseProfile,
    offline = true,
    noDefaultFeatures = noDefaultFeatures,
    features = featureList,
    manifestPath = manifestPath,
    targetDir = targetDir,
    package = package,
    target = target,
    after = compileAfter,
    extraEnv = env)

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
    config = vendoredConfig,
    locked = true,
    offline = true,
    # Without `--no-track`, cargo writes a `.crates.toml` ledger into the
    # root recording what it installed there. That is per-install state
    # about a directory this build owns outright, and it makes the staged
    # tree differ between a first run and a re-run.
    noTrack = true,
    # The root is this build's own staging tree, so a binary already there
    # is the previous run's; cargo must replace it, not refuse it.
    force = true,
    noDefaultFeatures = noDefaultFeatures,
    features = featureList,
    path = (if installPath.len > 0: extractedRel / installPath
            else: extractedRel),
    root = installRoot,
    targetDir = targetDir,
    target = target,
    after = @[compileEdge],
    extraEnv = env)
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
