## `node_package(...)` — the `build:`-block pipeline for a from-source
## npm/bun agent recipe. The JS sibling of `cargo_package`.
##
## Internally: fetch → vendor (offline `file:` mirror) → `npm ci --offline` +
## the project's own bundle script → install a node launcher. Like every
## from-source sibling this constructor emits its OWN fetch and vendor so the
## build-block fragment is self-contained; the `from-source-npm` convention
## emits the same-output fetch and same-id vendor and the engine coalesces
## them (they write to one `.repro/fetch` path), rather than the build block
## referencing a node that lives only in the convention's fragment.
##
## ## Why a launcher rather than a copied binary
##
## A cargo build installs a native `usr/bin/<name>`. An npm build produces a
## JavaScript bundle (`bundle/<name>.js`) that only runs under `node`, so
## `usr/bin/<name>` cannot be that file — it has to be a launcher that runs
## it. This constructor installs the bundle under `usr/lib/<name>/` and
## writes `usr/bin/<name>` (a `#!/usr/bin/env bash` launcher) plus
## `usr/bin/<name>.cmd` (Windows), each execing `node` on the bundle by a
## path relative to the launcher so the realized prefix stays relocatable.
## `node` itself resolves from PATH — it is a declared build/runtime dep, and
## the consuming activation decides which one runs.
##
## ## `--offline` is the point
##
## `npm ci --offline` is what a from-source npm build is FOR: the vendor step
## rewrote the lockfile into a `file:` mirror of the pinned closure, so a
## package the manifest missed fails here rather than being fetched.

import std/[options, os, strutils]

import repro_project_dsl
import repro_project_dsl/npm_vendor

import ../types/package_result

const
  FetchScratchSubdir = ".repro/fetch"
    ## Where the source tarball and its stamp land. The same literal each
    ## sibling constructor declares privately, and deliberately the same
    ## VALUE: the `from-source-npm` convention's own fetch emitter writes
    ## there too, so a divergence here would mean two downloads of one
    ## tarball.

proc npmFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "npm-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  ## Emit the source fetch when the recipe declared one — same shape as the
  ## sibling constructors' own helpers, writing the tarball and stamp to the
  ## shared `.repro/fetch` path so the convention's fetch coalesces with it.
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
    id = npmFetchActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "node_package.fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = fetchToolRefs))

proc node_package*(srcDir = "src";
                   bundleScript = "bundle";
                   entry: string;
                   destdir = "";
                   extraEnv: seq[(string, string)] = @[]):
    NodePackageResult =
  ## Fetch → offline-vendor → `npm ci --offline` + `npm run <bundleScript>` →
  ## install a launcher, for an upstream npm/bun agent.
  ##
  ## `entry` is the built bundle's entry file relative to `srcDir` (e.g.
  ## `bundle/gemini.js`) — what the installed launcher runs under node.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()

  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw
    elif srcDir.len > 0: srcDir
    else: "src"

  # Emit the fetch and the offline-mirror vendor HERE — the build-block
  # fragment has to contain every node its edges reference, and coalesces
  # with the convention's same-output fetch / same-id vendor.
  let fetchOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var vendorEdge = BuildActionDef()
  if projectRoot.len > 0:
    vendorEdge = emitNpmVendorAction(projectRoot, pkgName,
      (if fetchOpt.isSome: fetchOpt.get().id else: ""),
      (if fetchOpt.isSome and fetchOpt.get().outputs.len > 0:
         fetchOpt.get().outputs[0]
       else: ""))

  let src = extractedRel
  let effectiveDestdir =
    if destdir.len > 0: destdir
    elif projectRoot.len > 0: projectRoot / ".repro/build/node/out"
    else: ".repro/build/node/out"

  proc q(v: string): string = v.replace("\\", "/").replace("\"", "\\\"")

  # Build: `npm ci --offline` against the mirror, then the project's own
  # bundle script. Run under the extracted source root.
  var extraEnvPrefix = ""
  for (k, v) in extraEnv:
    extraEnvPrefix.add(k & "=\"" & q(v) & "\" ")
  var buildScript = "set -e; cd \"" & q(src) & "\"; "
  buildScript.add(extraEnvPrefix &
    "npm ci --offline --no-audit --no-fund --no-progress; ")
  buildScript.add(extraEnvPrefix & "npm run " & bundleScript & "; ")
  let compileEdge = buildAction(
    id = "node-build-" & pkgName,
    call = inlineExecCall(@["sh", "-c", buildScript], projectRoot),
    deps = (if vendorEdge.id.len > 0: @[vendorEdge.id] else: @[]),
    inputs = (if vendorEdge.outputs.len > 0: @[vendorEdge.outputs[0]]
              else: @[]),
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "node_package.build",
    toolIdentityRefs = @["sh", "npm", "node"])

  # Install: bundle → usr/lib/<name>/, and a launcher pair at usr/bin/<name>.
  let usr = effectiveDestdir / "usr"
  let libDir = usr / "lib" / pkgName
  let binDir = usr / "bin"
  let entryRel = entry
  var installScript = "set -e; "
  installScript.add("rm -rf \"" & q(libDir) & "\"; ")
  installScript.add("mkdir -p \"" & q(libDir) & "\" \"" & q(binDir) & "\"; ")
  installScript.add("cp -R \"" & q(src) & "/.\" \"" & q(libDir) & "/\"; ")
  # bash launcher: resolve our own dir, exec node on the bundle entry.
  installScript.add("printf '%s\\n' " &
    "'#!/usr/bin/env bash' " &
    "'d=\"$(cd \"$(dirname \"$0\")\" && pwd)\"' " &
    "'exec node \"$d/../lib/" & pkgName & "/" & entryRel & "\" \"$@\"' > \"" &
    q(binDir) & "/" & pkgName & "\"; ")
  installScript.add("chmod +x \"" & q(binDir) & "/" & pkgName & "\"; ")
  # Windows launcher.
  installScript.add("printf '%s\\r\\n' " &
    "'@echo off' " &
    "'node \"%~dp0\\..\\lib\\" & pkgName & "\\" &
      entryRel.replace("/", "\\") & "\" %*' > \"" &
    q(binDir) & "/" & pkgName & ".cmd\"; ")
  let installEdge = buildAction(
    id = "node-install-" & pkgName,
    call = inlineExecCall(@["sh", "-c", installScript], projectRoot),
    deps = @[compileEdge.id],
    inputs = @[],
    outputs = @[effectiveDestdir],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "node_package.install",
    toolIdentityRefs = @["sh", "rm", "mkdir", "cp", "printf", "chmod"])

  NodePackageResult(
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
