## `node_package(...)` — the `build:`-block pipeline for a from-source
## npm/bun agent recipe. The JS sibling of `cargo_package`.
##
## Internally: fetch → vendor (a private npm cache) → offline `npm ci` +
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
## ## Offline is the point
##
## An offline `npm ci` is what a from-source npm build is FOR: the vendor
## step loaded the pinned closure into a private npm cache, and this build
## reads ONLY that cache with `npm_config_offline=true`, so a package the
## manifest missed fails here rather than being fetched — and nothing in the
## host's own npm cache can quietly satisfy it.

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
                   name = "";
                   destdir = "";
                   extraEnv: seq[(string, string)] = @[]):
    NodePackageResult =
  ## Fetch → vendor into a private cache → offline `npm ci` +
  ## `npm run <bundleScript>` →
  ## install a launcher, for an upstream npm/bun agent.
  ##
  ## `entry` is the built bundle's entry file relative to `srcDir` (e.g.
  ## `bundle/gemini.js`) — what the installed launcher runs under node.
  ##
  ## `name` is the installed command — the name the recipe's
  ## `.executable(...)` slices, and what lands at `usr/bin/<name>`. It
  ## defaults to the entry's basename (`bundle/gemini.js` -> `gemini`); it is
  ## NOT the owning package's name, which for a source recipe is an internal
  ## identifier like `geminiCliSource` that no user types.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()

  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw
    elif srcDir.len > 0: srcDir
    else: "src"

  # Emit the fetch and the private-cache vendor HERE — the build-block
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

  # Build: `npm ci` against the vendor step's PRIVATE npm cache, then the
  # project's own bundle script. The cache and offline mode go in the
  # environment rather than on the `npm ci` command line so they also bind
  # every nested `npm` the bundle script runs — and so the host's own npm
  # cache can never satisfy a lookup (see `repro_project_dsl/npm_vendor`).
  var extraEnvPrefix = ""
  for (k, v) in extraEnv:
    extraEnvPrefix.add(k & "=\"" & q(v) & "\" ")
  var buildScript = "set -e; cd \"" & q(src) & "\"; "
  if projectRoot.len > 0:
    buildScript.add("export npm_config_cache=\"" &
      q(npmPrivateCacheDir(projectRoot)) & "\"; ")
  buildScript.add("export npm_config_offline=true npm_config_audit=false " &
    "npm_config_fund=false npm_config_update_notifier=false; ")
  buildScript.add(extraEnvPrefix & "npm ci --no-progress; ")
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

  # Install: the bundle → usr/lib/<name>/, and a launcher pair at
  # usr/bin/<name>.
  #
  # ONLY THE BUNDLE IS INSTALLED — the directory holding `entry`, plus the
  # source root's `package.json` (a bundle may read its own version from it),
  # which is also exactly what an npm-published agent package ships. Copying
  # the whole built tree would publish `node_modules` and every workspace's
  # sources: for gemini-cli that was a 970 MB prefix around a ~50 MB bundle,
  # and it is the prefix that goes to the shared binary cache.
  let binName =
    if name.len > 0: name
    else: entry.extractFilename.changeFileExt("")
  let usr = effectiveDestdir / "usr"
  let libDir = usr / "lib" / binName
  let binDir = usr / "bin"
  let entryRel = entry
  let entryDir = entry.parentDir.replace("\\", "/")
  var installScript = "set -e; "
  installScript.add("rm -rf \"" & q(libDir) & "\"; ")
  installScript.add("mkdir -p \"" & q(libDir) & "\" \"" & q(binDir) & "\"; ")
  if entryDir.len > 0:
    installScript.add("mkdir -p \"" & q(libDir / entryDir) & "\"; ")
    installScript.add("cp -R \"" & q(src / entryDir) & "/.\" \"" &
      q(libDir / entryDir) & "/\"; ")
  else:
    # An entry at the source root has no bundle directory to isolate; the
    # entry file is what runs.
    installScript.add("cp -f \"" & q(src / entryRel) & "\" \"" &
      q(libDir) & "/\"; ")
  installScript.add("if [ -f \"" & q(src / "package.json") & "\" ]; then " &
    "cp -f \"" & q(src / "package.json") & "\" \"" & q(libDir) & "/\"; fi; ")
  # bash launcher: resolve our own dir, exec node on the bundle entry.
  installScript.add("printf '%s\\n' " &
    "'#!/usr/bin/env bash' " &
    "'d=\"$(cd \"$(dirname \"$0\")\" && pwd)\"' " &
    "'exec node \"$d/../lib/" & binName & "/" & entryRel & "\" \"$@\"' > \"" &
    q(binDir) & "/" & binName & "\"; ")
  installScript.add("chmod +x \"" & q(binDir) & "/" & binName & "\"; ")
  # Windows launcher.
  installScript.add("printf '%s\\r\\n' " &
    "'@echo off' " &
    "'node \"%~dp0\\..\\lib\\" & binName & "\\" &
      entryRel.replace("/", "\\") & "\" %*' > \"" &
    q(binDir) & "/" & binName & ".cmd\"; ")
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
