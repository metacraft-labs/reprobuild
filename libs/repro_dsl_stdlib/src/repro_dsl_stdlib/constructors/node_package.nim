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
    # The extracted tree is what this fetch produces, and it is fixed by the
    # hash the script verifies: a fixed-output action (Cache-Scope P3.4), so
    # the portable lookup can resolve it — and everything built from it —
    # without the network.
    declaredOutputs = @[extracted],
    fixedOutput = true,
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
                   extraEnv: seq[(string, string)] = @[];
                   ignoreScripts = false):
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

  # THE BUILD RUNS IN A SCRATCH COPY of the fetched tree, and delivers only
  # the bundle. `npm ci` fills `node_modules` and the bundle script writes
  # `dist/` trees and then reads them back; done in the fetched `src/` that
  # mutated the fetch's own output (so its record no longer described it),
  # and every one of those read-backs was recorded as an input keyed by what
  # the PREVIOUS run had left there -- absent on any checkout where the build
  # never ran, so no other checkout could match it. A scratch directory is
  # emptied by the engine before the action runs and nothing under it is
  # evidence (`BuildAction.scratchDirs`, BuildXL's pip temp directory); the
  # bundle goes to `distDir`, the edge's declared output.
  let underProject = proc (rel: string): string =
    if projectRoot.len > 0: projectRoot / rel else: rel
  let scratchDir = underProject(".repro/build/node-work")
  let workTree = scratchDir / "src"
  let distDir = underProject(".repro/build/node/dist")
  let entryDirOf = entry.parentDir.replace("\\", "/")

  # Build: `npm ci` against the vendor step's PRIVATE npm cache, then the
  # project's own bundle script. The cache and offline mode go in the
  # environment rather than on the `npm ci` command line so they also bind
  # every nested `npm` the bundle script runs — and so the host's own npm
  # cache can never satisfy a lookup (see `repro_project_dsl/npm_vendor`).
  var extraEnvPrefix = ""
  for (k, v) in extraEnv:
    extraEnvPrefix.add(k & "=\"" & q(v) & "\" ")
  var buildScript = "set -e; mkdir -p \"" & q(workTree) & "\"; " &
    "cp -R \"" & q(src) & "/.\" \"" & q(workTree) & "/\"; " &
    "cd \"" & q(workTree) & "\"; "
  if projectRoot.len > 0:
    buildScript.add("export npm_config_cache=\"" &
      q(npmPrivateCacheDir(projectRoot)) & "\"; ")
  # `logs_max=0`: npm otherwise writes a timestamped `_logs/<time>-debug-0.log`
  # into the cache on every invocation and probes the older ones to rotate
  # them. That is npm's bookkeeping, not an input, but the monitor rightly
  # observes it, so every run of this edge would observe different paths
  # and no two runs could ever be compared (the determinism probe) or share
  # a portable record.
  buildScript.add("export npm_config_offline=true npm_config_audit=false " &
    "npm_config_fund=false npm_config_update_notifier=false " &
    "npm_config_logs_max=0; ")
  # HERMETIC TOOL CONFIGURATION. Every one of these was observed reading
  # HOST state on a gemini-cli build, which made the edge's result depend
  # on the machine rather than on its inputs:
  #   * npm reads the user's and the global `npmrc` — pointed at files under
  #     the project that do not exist, so npm uses its defaults;
  #   * git (a build script's `git rev-parse` for version metadata) reads
  #     the user's and the system's config AND walks up out of the fetched
  #     tree into whatever repository encloses the checkout — gemini-cli
  #     shipped the PACKAGING repository's commit as its own. With the
  #     ceiling at the project root git finds no repository, and a script
  #     falls back exactly as it does on a source tarball;
  #   * node's OpenSSL loads the system `openssl.cnf` at startup — pointed
  #     at an empty file under the project;
  #   * npm itself reads `~/.gitconfig` (its path comes from the home
  #     directory, not from git's variables), and node keeps a V8 compile
  #     cache in the host temp directory — the home directory is a
  #     project-local one, and the compile cache is off.
  if projectRoot.len > 0:
    let hermetic = scratchDir / "hermetic"
    buildScript.add("mkdir -p \"" & q(hermetic / "home") & "\"; ")
    buildScript.add("export HOME=\"" & q(hermetic / "home") &
      "\" USERPROFILE=\"" & q(hermetic / "home") &
      "\" NODE_DISABLE_COMPILE_CACHE=1; ")
    buildScript.add(": > \"" & q(hermetic / "openssl.cnf") & "\"; ")
    buildScript.add("export npm_config_userconfig=\"" &
      q(hermetic / "npmrc") & "\" npm_config_globalconfig=\"" &
      q(hermetic / "global-npmrc") & "\" GIT_CONFIG_NOSYSTEM=1 " &
      "GIT_CONFIG_GLOBAL=\"" & q(hermetic / "gitconfig") & "\" " &
      "GIT_CEILING_DIRECTORIES=\"" & q(projectRoot) & "\" " &
      "OPENSSL_CONF=\"" & q(hermetic / "openssl.cnf") & "\"; ")
  # `ignoreScripts`: skip the dependencies' install scripts. A recipe opts in
  # only when the bundle is proven byte-identical without them — gemini-cli
  # compiles `@github/keytar` with node-gyp there (host MSVC, a Python found
  # by probing well-known install locations, node headers cached in the
  # user profile), and the bundle only loads keytar optionally at run time.
  buildScript.add(extraEnvPrefix & "npm ci --no-progress" &
    (if ignoreScripts: " --ignore-scripts" else: "") & "; ")
  buildScript.add(extraEnvPrefix & "npm run " & bundleScript & "; ")
  # Deliver the bundle: the directory holding `entry` (or the entry itself,
  # when it sits at the source root) and the root `package.json`, at the
  # same relative paths, which is everything the install edge copies.
  buildScript.add("rm -rf \"" & q(distDir) & "\"; ")
  if entryDirOf.len > 0:
    buildScript.add("mkdir -p \"" & q(distDir / entryDirOf) & "\"; " &
      "cp -R \"" & q(workTree / entryDirOf) & "/.\" \"" &
      q(distDir / entryDirOf) & "/\"; ")
  else:
    buildScript.add("mkdir -p \"" & q(distDir) & "\"; " &
      "cp -f \"" & q(workTree / entry) & "\" \"" & q(distDir) & "/\"; ")
  buildScript.add("if [ -f package.json ]; then cp -f package.json \"" &
    q(distDir) & "/\"; fi")
  let compileEdge = buildAction(
    id = "node-build-" & pkgName,
    call = inlineExecCall(@["sh", "-c", buildScript], projectRoot),
    deps = (if vendorEdge.id.len > 0: @[vendorEdge.id] else: @[]),
    inputs = (if vendorEdge.outputs.len > 0: @[vendorEdge.outputs[0]]
              else: @[]),
    outputs = @[],
    # The bundle is what the install edge reads. Declared, a record can name
    # it (so another host resolves the install without it on disk) and the
    # determinism probe has something to compare.
    declaredOutputs = @[distDir],
    scratchDirs = @[scratchDir],
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
    installScript.add("cp -R \"" & q(distDir / entryDir) & "/.\" \"" &
      q(libDir / entryDir) & "/\"; ")
  else:
    # An entry at the source root has no bundle directory to isolate; the
    # entry file is what runs.
    installScript.add("cp -f \"" & q(distDir / entryRel.extractFilename) &
      "\" \"" & q(libDir) & "/\"; ")
  installScript.add("if [ -f \"" & q(distDir / "package.json") &
    "\" ]; then cp -f \"" & q(distDir / "package.json") & "\" \"" &
    q(libDir) & "/\"; fi; ")
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
