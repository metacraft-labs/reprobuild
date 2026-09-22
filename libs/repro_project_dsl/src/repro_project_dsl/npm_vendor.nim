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
## ## How offline `npm ci` is achieved
##
## npm has no vendored-directory source the way cargo's `[source]` config
## gives one, and `npm cache add` does not populate the cacache in the form
## `npm ci --offline` reads (npm 11 treats a local path as a git spec). What
## DOES work — verified — is the offline-mirror rewrite: place every archive
## under `<src>/tarballs/`, rewrite the lockfile's `resolved` URLs to
## `file:tarballs/<archive>` and drop their registry `integrity`, and then
## `npm ci --offline` installs from the local tarballs with no network,
## creating `.bin` links and running lifecycle scripts exactly as a normal
## install would. The recipe's own `build:` block owns the `npm ci` and the
## bundle, as every from-source sibling owns its compile.
##
## ## Why the manifest is verified here
##
## Each archive is verified against the manifest's SHA-256 — the digest the
## generator computed from the bytes the registry served when the pin was
## taken — so a substituted or corrupted tarball is caught here rather than
## surfacing as a mysterious build failure. The `resolved` rewrite then
## drops the lockfile's own sha512 `integrity`, because reprobuild's SHA-256
## is the integrity that governs from this point.

import std/[os, strutils]

import repro_core/paths
import repro_project_dsl
import repro_project_dsl/shell_fetch

const
  NpmBuildClosureManifestName* = "npm-build-closure.manifest"
    ## The committed build-closure manifest, beside the recipe's `repro.nim`.

proc npmVendorActionId*(packageName: string): string =
  "npm-vendor-" & packageName

proc npmBuildClosureManifestPath*(projectRoot: string): string =
  projectRoot / NpmBuildClosureManifestName

proc npmSourceRoot*(projectRoot: string): string =
  ## Where the fetch action extracts the source — the tree that holds
  ## `package-lock.json`, and under which `npm ci` runs.
  projectRoot / "src"

proc npmTarballsDir*(projectRoot: string): string =
  ## The offline mirror the rewritten lockfile's `file:` paths point at. It
  ## sits at the source root because `file:tarballs/<x>` in a lockfile is
  ## resolved relative to the lockfile's own directory.
  npmSourceRoot(projectRoot) / "tarballs"

proc npmVendorCacheDir*(projectRoot: string): string =
  ## Download cache, keyed by archive basename, so a re-run of the vendor
  ## action reuses what it already fetched and only the mirror is rebuilt.
  projectRoot / ".repro-npm-vendor-cache"

proc npmVendorStampPath*(projectRoot: string): string =
  projectRoot / "npm-vendor.stamp"

proc npmLockfilePath*(projectRoot: string): string =
  npmSourceRoot(projectRoot) / "package-lock.json"

proc emitNpmVendorAction*(projectRoot, packageName: string;
                          fetchActionId, fetchStamp: string):
                            BuildActionDef =
  ## The single action that materialises the offline npm mirror.
  ##
  ## Depends on the source fetch: it writes `tarballs/` into the extracted
  ## tree and rewrites the `package-lock.json` that arrives with the source,
  ## neither of which exists until the source is unpacked.
  let manifest = npmBuildClosureManifestPath(projectRoot)
  let cacheDir = npmVendorCacheDir(projectRoot)
  let tarballs = npmTarballsDir(projectRoot)
  let lockfile = npmLockfilePath(projectRoot)
  let stamp = npmVendorStampPath(projectRoot)
  createDir(extendedPath(projectRoot))

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  var script = "set -e; "
  script.add("mkdir -p \"" & q(cacheDir) & "\"; ")
  # The mirror is rebuilt from scratch: a stale tarball left by a previous
  # closure would still satisfy a `file:` reference the lockfile no longer
  # carries, and the build would succeed against a dependency the manifest
  # no longer names.
  script.add("rm -rf \"" & q(tarballs) & "\"; ")
  script.add("mkdir -p \"" & q(tarballs) & "\"; ")
  # One space-separated triple per line: <node_modules-path> <sha256> <url>.
  # Only the sha256 and url are used here; the path is what the generator
  # keyed the closure on and is carried for readability/debuggability.
  script.add("while read -r repro_path repro_sha repro_url; do ")
  script.add("case \"$repro_path\" in ''|'#'*) continue;; esac; ")
  # Key the mirror by the URL's HOST-RELATIVE PATH, not its basename. Two
  # DIFFERENT packages can share a basename — `@jsonjoy.com/base64` and
  # `@protobufjs/base64` both resolve to `.../base64-1.1.2.tgz` — and a
  # basename key would (1) make the second entry's sha256 check run against
  # the first's already-cached bytes and fail the whole vendor step, and
  # (2) rewrite both `resolved` fields to one `file:` path so `npm ci`
  # installed one package's tarball for the other. The path after the host
  # (`@jsonjoy.com/base64/-/base64-1.1.2.tgz`) is unique per package, and the
  # sed below reconstructs exactly the same path from the lockfile URL.
  script.add("repro_rel=\"${repro_url#*://}\"; ")
  script.add("repro_rel=\"${repro_rel#*/}\"; ")
  script.add("repro_cached=\"" & q(cacheDir) & "/$repro_rel\"; ")
  script.add("mkdir -p \"$(dirname \"$repro_cached\")\"; ")
  script.add("if [ ! -f \"$repro_cached\" ]; then ")
  script.add("curl -fsSL " & CurlFetchRetryArgs &
    " -o \"$repro_cached.part\" \"$repro_url\"; ")
  script.add("mv -f \"$repro_cached.part\" \"$repro_cached\"; fi; ")
  # Verified every run, not only after a download: a cache entry corrupted
  # in place is exactly what this catches.
  script.add("printf '%s  %s\\n' \"$repro_sha\" \"$repro_cached\" | " &
    "sha256sum -c - > /dev/null; ")
  script.add("repro_dest=\"" & q(tarballs) & "/$repro_rel\"; ")
  script.add("mkdir -p \"$(dirname \"$repro_dest\")\"; ")
  script.add("cp -f \"$repro_cached\" \"$repro_dest\"; ")
  script.add("done < \"" & q(manifest) & "\"; ")
  # Rewrite the lockfile into an offline mirror: every registry `resolved`
  # becomes a `file:tarballs/<host-relative-path>` reference, and its
  # registry `integrity` is dropped (reprobuild's verified sha256 governs
  # from here). `[^/]+` matches the host so the capture is the full unique
  # path. `npm ci --offline`, which the recipe's build runs next, then
  # installs entirely from the local tarballs. See the module doc for why
  # this rather than the npm cache.
  script.add("sed -i -E 's#(\"resolved\": \")https?://[^/]+/" &
    "([^\"]+\\.tgz)\"#\\1file:tarballs/\\2\"#g; /\"integrity\":/d' \"" &
    q(lockfile) & "\"; ")
  script.appendVerifiedFetchStamp(stamp)

  var inputs: seq[string] = @[manifest]
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
      "printf", "cp", "sed"])
