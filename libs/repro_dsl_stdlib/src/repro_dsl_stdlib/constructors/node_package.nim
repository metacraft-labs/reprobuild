## `node_package(...)` — the `build:`-block pipeline for a from-source
## npm/bun agent recipe. The JS sibling of `cargo_package`.
##
## Internally it emits `npm ci --offline` + the project's own bundle script,
## then a node-launcher install. The fetch and the offline-mirror vendor are
## emitted by the `from-source-npm` convention; this constructor depends on
## the vendor by its known action id + stamp rather than re-emitting it, so
## the two halves of one recipe do not duplicate the closure fetch.
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

import std/[os, strutils, tables]

import repro_project_dsl
import repro_project_dsl/npm_vendor

import ../types/package_result

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

  # The fetch and the offline-mirror vendor are emitted by the from-source-npm
  # convention; depend on the vendor by its known id + stamp so the build
  # cannot start before the mirror is on disk. (The convention refuses to emit
  # when the closure manifest is absent, so recognition is the gate.)
  let vendorId = npmVendorActionId(pkgName)
  let vendorStamp =
    if projectRoot.len > 0: npmVendorStampPath(projectRoot) else: ""

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
    deps = @[vendorId],
    inputs = if vendorStamp.len > 0: @[vendorStamp] else: @[],
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "node_package.build",
    toolIdentityRefs = @["sh", "npm", "node"])

  # Install: bundle → usr/lib/<name>/, and a launcher pair at usr/bin/<name>.
  let usr = effectiveDestdir / "usr"
  let libDir = usr / "lib" / pkgName
  let binDir = usr / "bin"
  # The bundle output directory is `entry`'s parent (e.g. `bundle` for
  # `bundle/gemini.js`); when the entry sits at the source root the whole
  # source is what the bundle needs, but the common agent shape is a single
  # `bundle/` dir, so copy that dir and point the launcher inside it.
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
