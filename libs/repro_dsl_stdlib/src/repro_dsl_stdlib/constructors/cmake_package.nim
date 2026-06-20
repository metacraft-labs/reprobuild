## DSL-port M9.R.2b — Layer-1 ``cmake_package`` multi-artifact
## constructor.
##
## Internally drives ``cmake.configure`` + ``cmake.build`` +
## ``cmake.install`` and returns a ``CmakePackageResult``.
##
## ## M9.R.12.4 — auto-emit fetch action when recipe declared one
##
## See ``autotools_package`` / ``meson_package`` for the canonical
## rationale. Per-project providers don't dispatch through the
## standard-provider's convention layer, so the fetch action has to be
## emitted from the constructor body for recipes with an explicit
## ``build:`` block.

{.experimental: "callOperator".}

import std/[options, os, strutils]

import repro_project_dsl

import ../types/package_result
import ../packages/cmake as cmake_module
import ../packages/sh as sh_module

# ---------------------------------------------------------------------------
# Fetch action (M9.R.12.4) — shared shape with ``autotools_package`` /
# ``meson_package``.
# ---------------------------------------------------------------------------

const FetchScratchSubdir = ".repro/fetch"

proc cmakeFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "cmake-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
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
  let hashAlgTag =
    case spec.hashAlg
    of dshaSha256: "sha256"
    of dshaBlake3: "blake3"
  let escapedUrl = spec.url.replace("\"", "\\\"")
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("mkdir -p \"" & escapedExtracted & "\"; ")
  script.add("if [ ! -f \"" & escapedTarball & "\" ]; then ")
  script.add("curl -fsSL -o \"" & escapedTarball & "\" \"" & escapedUrl &
    "\"; fi; ")
  case spec.hashAlg
  of dshaSha256:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | sha256sum -c -; ")
  of dshaBlake3:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | b2sum -a blake3 -c - || ")
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | blake3sum -c -; ")
  # M9.R.13b.4 — ``--force-local`` so Windows tar (MSYS2 / Git-for-
  # Windows) doesn't interpret ``D:/...`` as a ``host:`` rsh path. See
  # the matching fix in ``autotools_package.nim`` for the full rationale.
  script.add("tar --force-local -xf \"" & escapedTarball & "\" -C \"" &
    escapedExtracted & "\" --strip-components=" & $spec.extractStrip & "; ")
  script.add("touch \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let act = buildAction(
    id = cmakeFetchActionId(packageName),
    call = inlineExecCall(argv),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cmake_package.fetch." & hashAlgTag,
    toolIdentityRefs = @["sh"])
  some(act)

proc cmake_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    generator = "";
                    cacheVars: seq[string] = @[];
                    target = ""): CmakePackageResult =
  ## Configure → build → install pipeline for an upstream cmake
  ## project. v1 leaves component selection up to the recipe
  ## (``component`` field on the install call); the standard layout
  ## table populated on the result mirrors meson's.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var configureAfter: seq[BuildActionDef] = @[]
  if fetchActOpt.isSome:
    configureAfter.add(fetchActOpt.get())
  let configureEdge = cmake.configure(
    srcDir = srcDir,
    buildDir = buildDir,
    generator = generator,
    cacheVars = cacheVars,
    after = configureAfter)
  let buildEdge = cmake.build(
    buildDir = buildDir,
    target = target)
  let installEdge = cmake.install(
    buildDir = buildDir,
    prefix = destdir & prefix)
  CmakePackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: destdir,
    components: standardComponents())
