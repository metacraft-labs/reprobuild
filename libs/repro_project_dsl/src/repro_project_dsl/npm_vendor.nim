## The npm build-closure vendor action — the JS sibling of `cargo_vendor`.
##
## ## What it is for
##
## A from-source JS/bun agent (gemini-cli, qwen-code, opencode) builds by
## running `npm ci` and then its own bundle script (esbuild / tsc / a
## bundler). That install is the closure this action materialises: every
## archive a full `npm ci` would fetch — dev dependencies and every
## workspace's dependencies — which a lockfileVersion 2/3 lock has already
## resolved into its `packages` map, and which
## `reprobuild-llm-agent-packages/tools/npm_closure_manifest.nim
## --build-closure` writes out as a committed `<path> <sha256> <url>`
## manifest.
##
## ## How offline `npm ci` is achieved: a private, content-addressed cache
##
## Every archive is downloaded once, verified against the manifest's
## SHA-256, and loaded into a PRIVATE npm cache (`npmPrivateCacheDir`) with
## `npm cache add file:<archive>`. The lockfile is left exactly as written —
## registry `resolved` URLs and sha512 `integrity` intact — and the build
## (`node_package`) runs `npm ci` with `npm_config_cache` pointing at that
## cache and `npm_config_offline=true`. npm's fetcher looks a tarball up in
## its cache BY INTEGRITY DIGEST before it would touch the network, so every
## archive resolves from the cache, and one the manifest missed fails
## `ENOTCACHED` instead of being fetched. This is npm's ordinary install
## path, and the cache is private to the build: nothing on the host's
## `%LOCALAPPDATA%\npm-cache` / `~/.npm` can satisfy a lookup, so a build
## that passes here passes on a clean machine.
##
## Two earlier designs, recorded because both looked right and were not:
##
## * `npm cache add tarballs/x.tgz` appeared "not to work". It does; a BARE
##   relative path is parsed as a GitHub shorthand (`user/repo`) and sent to
##   `git ls-remote`. An explicit `file:` spec is a local tarball.
## * Rewriting every `resolved` to `file:tarballs/<archive>` and dropping
##   `integrity` does install offline — on a small closure. On gemini-cli's
##   1464-entry closure `npm ci --offline` grew to 9–24 GB of OFF-HEAP
##   memory in `reify` (V8 heap capped at 2 GB, working set still 9 GB)
##   against a 484 MB mirror, and twice drove the host out of memory. The
##   private cache installs the same closure in 11 s at a 1.2 GB peak.
##
## ## Why the manifest is verified here
##
## Each archive is verified against the manifest's SHA-256 — the digest the
## generator computed from the bytes the registry served when the pin was
## taken — so a substituted or corrupted tarball is caught here rather than
## surfacing as a mysterious build failure. npm then verifies the lockfile's
## own sha512 `integrity` against the same bytes when it installs them, so
## both pins hold.

import std/[os, strutils]

import blake3

import repro_core/paths
import repro_project_dsl
import repro_project_dsl/shell_fetch

const
  NpmBuildClosureManifestName* = "npm-build-closure.manifest"
    ## The committed build-closure manifest, beside the recipe's `repro.nim`.
  NpmBuildClosureLockName* = "npm-build-closure.package-lock.json"
    ## An OPTIONAL committed lockfile, beside the recipe, that replaces the
    ## one the fetched source ships before the build installs from it.
    ##
    ## Why it has to exist: an upstream's committed `package-lock.json` is
    ## not always installable as written. gemini-cli v0.59.0's is not —
    ## workspace `package.json`s pin `tar@7.5.8`, `vitest@3.2.4`,
    ## `clipboardy@5.2.0`, `typescript@5.8.3` while the lock nests
    ## `7.5.11`, `3.1.1`, `5.2.1`, `5.9.3` under those workspaces, and one
    ## hoisted `ansi-styles` is shared across conflicting `overrides` scopes.
    ## Online, `npm ci` silently repairs both by re-resolving those edges
    ## from the registry (installing a tree that is NOT the lockfile);
    ## offline it cannot, and fails `ENOTCACHED`. The committed lock is the
    ## tree upstream's own `npm ci` actually installs, written down so
    ## `npm ci --offline` reproduces it with no registry metadata at all.
    ## Its closure manifest must be generated from THIS lock, not upstream's.
  NpmCacheAddBatch = 100
    ## Archives per `npm cache add` invocation: keeps each command line well
    ## under the Windows `CreateProcess` 32 KiB limit while not paying node's
    ## start-up cost once per archive.

proc npmVendorActionId*(packageName: string): string =
  "npm-vendor-" & packageName

proc npmBuildClosureManifestPath*(projectRoot: string): string =
  projectRoot / NpmBuildClosureManifestName

proc npmBuildClosureLockPath*(projectRoot: string): string =
  projectRoot / NpmBuildClosureLockName

proc npmSourceRoot*(projectRoot: string): string =
  ## Where the fetch action extracts the source — the tree that holds
  ## `package-lock.json`, and under which `npm ci` runs.
  projectRoot / "src"

proc npmVendorRoot*(projectRoot: string): string =
  ## Scratch root for everything the vendor step writes. Under `.repro/`
  ## (like `cargo_lock.CargoVendorSubdir`) so `repro clean` takes it and no
  ## artefact lands in the recipe directory, where it would show up as an
  ## untracked file in the catalog's checkout.
  projectRoot / ".repro" / "npm-vendor"

proc npmVendorCacheDir*(projectRoot: string): string =
  ## Download cache, keyed by the archive URL's host-relative path (unique
  ## per package, unlike its basename), so a re-run of the vendor action
  ## reuses what it already fetched and only the npm cache is rebuilt.
  npmVendorRoot(projectRoot) / "archives"

proc npmPrivateCacheDir*(projectRoot: string): string =
  ## The npm cache the build installs from — and the ONLY one it may read.
  ## `node_package` points `npm_config_cache` here for `npm ci` and for every
  ## nested `npm` the project's own bundle script runs.
  npmVendorRoot(projectRoot) / "npm-cache"

proc npmVendorStampPath*(projectRoot: string): string =
  ## The vendor action's output, and what the build orders itself after.
  npmVendorRoot(projectRoot) / "vendor.stamp"

proc npmLockfilePath*(projectRoot: string): string =
  npmSourceRoot(projectRoot) / "package-lock.json"

proc emitNpmVendorAction*(projectRoot, packageName: string;
                          fetchActionId, fetchStamp: string):
                            BuildActionDef =
  ## The single action that materialises the build's private npm cache.
  ##
  ## Depends on the source fetch: it installs the committed lock over the
  ## `package-lock.json` that arrives with the source, which does not exist
  ## until the source is unpacked.
  let manifest = npmBuildClosureManifestPath(projectRoot)
  let cacheDir = npmVendorCacheDir(projectRoot)
  let npmCache = npmPrivateCacheDir(projectRoot)
  let lockfile = npmLockfilePath(projectRoot)
  let stamp = npmVendorStampPath(projectRoot)
  createDir(extendedPath(npmVendorRoot(projectRoot)))

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  # The POPULATE body: download, verify and load every archive. Built on
  # its own so the up-to-date token below can bind it.
  var script = ""
  script.add("mkdir -p \"" & q(cacheDir) & "\"; ")
  # The npm cache is rebuilt from scratch: an entry left by a previous
  # closure would still satisfy a lookup, and the build could succeed
  # against an archive the manifest no longer names.
  script.add("rm -rf \"" & q(npmCache) & "\"; ")
  script.add("mkdir -p \"" & q(npmCache) & "\"; ")
  script.add("repro_n=0; repro_batch=''; ")
  # One space-separated triple per line: <node_modules-path> <sha256> <url>.
  script.add("while read -r repro_path repro_sha repro_url; do ")
  script.add("case \"$repro_path\" in ''|'#'*) continue;; esac; ")
  # Key the download cache by the URL's HOST-RELATIVE PATH, not its
  # basename: two DIFFERENT packages can share a basename —
  # `@jsonjoy.com/base64` and `@protobufjs/base64` both resolve to
  # `.../base64-1.1.2.tgz` — and a basename key made the second entry's
  # sha256 check run against the first's already-cached bytes. The path
  # after the host (`@jsonjoy.com/base64/-/base64-1.1.2.tgz`) is unique.
  script.add("repro_rel=\"${repro_url#*://}\"; ")
  script.add("repro_rel=\"${repro_rel#*/}\"; ")
  script.add("repro_cached=\"" & q(cacheDir) & "/$repro_rel\"; ")
  script.add("mkdir -p \"${repro_cached%/*}\"; ")
  script.add("if [ ! -f \"$repro_cached\" ]; then ")
  script.add("curl -fsSL " & CurlFetchRetryArgs &
    " -o \"$repro_cached.part\" \"$repro_url\"; ")
  script.add("mv -f \"$repro_cached.part\" \"$repro_cached\"; fi; ")
  # Verified every run, not only after a download: a cache entry corrupted
  # in place is exactly what this catches.
  script.add("printf '%s  %s\\n' \"$repro_sha\" \"$repro_cached\" | " &
    "sha256sum -c - > /dev/null; ")
  # Queue it for the npm cache. `file:` is load-bearing: without it npm
  # reads `@scope/name/-/x.tgz` as a GitHub shorthand. The spec is relative
  # to the download cache (the `cd` below), and npm package paths carry no
  # whitespace, so plain word-splitting of the batch is safe.
  script.add("repro_batch=\"$repro_batch file:$repro_rel\"; ")
  script.add("repro_n=$((repro_n + 1)); ")
  script.add("if [ \"$repro_n\" -ge " & $NpmCacheAddBatch & " ]; then ")
  script.add("(cd \"" & q(cacheDir) & "\" && npm cache add --cache \"" &
    q(npmCache) & "\" $repro_batch); repro_n=0; repro_batch=''; fi; ")
  script.add("done < \"" & q(manifest) & "\"; ")
  script.add("if [ -n \"$repro_batch\" ]; then ")
  script.add("(cd \"" & q(cacheDir) & "\" && npm cache add --cache \"" &
    q(npmCache) & "\" $repro_batch); fi; ")
  # A committed lock (see `NpmBuildClosureLockName`) replaces the fetched
  # one, so `npm ci` installs the lock the closure manifest was generated
  # from. Decided at emission time so its presence is part of the action,
  # and the file is an input so an edit to it re-runs the vendor. It runs
  # on EVERY execution, the up-to-date path included: the fetch action
  # re-extracts `src/` each run, which restores upstream's lock.
  let overrideLock = npmBuildClosureLockPath(projectRoot)
  let hasOverrideLock = fileExists(overrideLock)
  var prologue = "set -e; "
  if hasOverrideLock:
    prologue.add("cp -f \"" & q(overrideLock) & "\" \"" & q(lockfile) &
      "\"; ")

  # UP-TO-DATE SKIP. This action is non-cacheable (it reaches the network),
  # so the engine runs it on every build — and under automatic monitoring
  # re-populating gemini-cli's 1340-archive cache took about an hour. It is
  # skipped when BOTH hold:
  #   * the stamp carries a token over the populate program AND the
  #     manifest's and committed lock's CONTENTS (so a changed pin, closure
  #     or lock re-populates), and
  #   * the private cache holds one index entry per unique archive URL (so
  #     a deleted or half-written cache re-populates).
  # Skipping is safe where it could be wrong: `npm ci` re-verifies every
  # tarball against the lockfile's sha512 `integrity`, so a corrupted entry
  # fails the build loudly (and a missing one fails `ENOTCACHED`) instead of
  # producing a different product. The count uses only shell builtins, so
  # the check adds no tool to the action's identity.
  var manifestText = ""
  try: manifestText = readFile(manifest)
  except CatchableError: discard
  var lockText = ""
  if hasOverrideLock:
    try: lockText = readFile(overrideLock)
    except CatchableError: discard
  var uniqueUrls: seq[string] = @[]
  for line in manifestText.splitLines():
    let fields = line.strip().splitWhitespace()
    if fields.len == 3 and not fields[0].startsWith("#") and
        fields[2] notin uniqueUrls:
      uniqueUrls.add(fields[2])
  let token = "repro-npm-vendor-v1:" & blake3.toHex(blake3.digest(
    script & "\n--manifest--\n" & manifestText & "\n--lock--\n" & lockText))
  let escapedStamp = q(stamp)
  let indexGlob = q(npmCache) & "/_cacache/index-v5/*/*/*"
  var full = prologue
  full.add("repro_up=0; if [ -f \"" & escapedStamp & "\" ] && " &
    "IFS= read -r repro_tok < \"" & escapedStamp & "\" && " &
    "[ \"$repro_tok\" = \"" & token & "\" ]; then repro_have=0; " &
    "for repro_f in " & indexGlob & "; do " &
    "[ -f \"$repro_f\" ] && repro_have=$((repro_have + 1)); done; " &
    "[ \"$repro_have\" -ge " & $uniqueUrls.len & " ] && repro_up=1; fi; ")
  full.add("if [ \"$repro_up\" = 1 ]; then printf '%s\\n' " &
    "'npm vendor: private cache up to date (" & $uniqueUrls.len &
    " archives)'; else " & script & "printf '%s\\n' '" & token &
    "' > \"" & escapedStamp & "\"; fi")
  script = full

  var inputs: seq[string] = @[manifest]
  if hasOverrideLock:
    inputs.add(overrideLock)
  if fetchStamp.len > 0:
    inputs.insert(fetchStamp, 0)
  buildAction(
    id = npmVendorActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = if fetchActionId.len > 0: @[fetchActionId] else: @[],
    inputs = inputs,
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "npm-vendor.registry",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = @["sh", "rm", "mkdir", "curl", "mv", "sha256sum",
      "printf", "cp", "npm", "node"])
