## The vendored-closure acquisition step for from-source Rust recipes.
##
## Sibling of `shell_fetch`, and here for the same reason: two libraries
## above this one both need it and neither can see the other. The
## `from-source-cargo` CONVENTION (in `repro_standard_provider`) emits this
## action so its sentinel orders after a usable tree; the `cargo_package`
## CONSTRUCTOR (in `repro_dsl_stdlib`) emits it so the compile orders after
## the same stamp. Those two libraries are siblings, so the shared emitter
## has to sit below both.
##
## ## Why a second acquisition step exists at all
##
## The `.crate` tarball a recipe fetches contains the package and nothing
## else. `cargo build --offline` needs every transitive dependency already
## on disk, so a from-source Rust recipe that stops at the source fetch is a
## recipe that cannot build without the network — the property the whole
## from-source tier exists to have.
##
## ## Why a committed manifest rather than a lockfile read
##
## The closure could be derived from the `Cargo.lock` inside the fetched
## source, but not at emission time: graph emission happens before the fetch
## action has run, so at that point the lockfile does not exist. Deriving it
## later, at build time, would make the largest input to the build invisible
## to review and to the action fingerprint until the build was already
## running.
##
## So the recipe commits the closure beside itself, generated from an
## upstream lockfile by `repro_core/cargo_lock`. This emitter reads that file
## at emission time, which is what lets its content reach the action's
## fingerprint: move a pinned dependency and the action re-runs.
##
## ## Shape of the emitted action
##
## One action, not one per crate. A closure of three to five hundred crates
## would otherwise be as many graph nodes whose only purpose is to land files
## in one directory — and on Windows the argv that would carry them exceeds
## what `CreateProcess` accepts long before that. The script is a fixed loop
## over the manifest:
##
##   1. `curl` the crate into a cache path keyed by `<name>-<version>`,
##      skipping the download when it is already there;
##   2. verify it against the manifest's SHA-256, which came from the
##      lockfile and is the only thing the download is checked against;
##   3. unpack it into `<vendor>/<name>-<version>` — the directory name cargo
##      expects, and also the top-level directory inside the `.crate`
##      tarball, so no strip is needed;
##   4. write the `.cargo-checksum.json` cargo requires beside it.
##
## Then the `.cargo/config.toml` that redirects both crates.io spellings to
## the vendored directory, and the stamp.
##
## The loop reads the manifest from disk rather than carrying it in the
## script, so the script stays a few hundred bytes whatever the closure's
## size.
##
## Like `shell_fetch`'s consumers, the action is non-cacheable: it reaches
## the network and has no monitorable file-dependency evidence. Its stamp is
## what short-circuits the work on a second run.

import std/[os, strutils]

import repro_core/cargo_lock
import repro_core/paths
import repro_project_dsl

export cargo_lock

# Imported by CONSUMERS rather than re-exported from ``repro_project_dsl``
# itself. The emitter returns a ``BuildActionDef`` and calls
# ``buildAction`` / ``inlineExecCall``, so it sits above the DSL's own type
# and runtime modules; pulling it into the package module would make the
# package module depend on something that depends on the package module.

proc cargoVendorActionId*(packageName: string): string =
  ## Stable per-package action id, so a constructor and a convention that
  ## both emit this step name the SAME action and the engine coalesces them
  ## instead of running the closure twice.
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "cargo-vendor-" & sanitized

proc readVendorManifest*(projectRoot: string): seq[VendorEntry] =
  ## Read and validate the committed manifest.
  ##
  ## Raises when it is absent or malformed rather than emitting an action
  ## that would fail later: a from-source Rust recipe without a pinned
  ## closure is not a recipe that builds offline, and saying so at emission
  ## time names the file that is missing.
  let path = cargoVendorManifestPath(projectRoot)
  if not fileExists(extendedPath(path)):
    raise newException(CargoLockError,
      "from-source-cargo: no " & CargoVendorManifestName & " beside the " &
      "recipe at " & projectRoot & ". The dependency closure has to be " &
      "pinned before the package can build offline; generate it from the " &
      "upstream Cargo.lock.")
  let text =
    try:
      readFile(extendedPath(path))
    except CatchableError as err:
      raise newException(CargoLockError,
        "from-source-cargo: cannot read " & path & ": " & err.msg)
  parseVendorManifest(text)

proc emitCargoVendorAction*(projectRoot, packageName: string;
                            plan: openArray[VendorEntry];
                            fetchActionId, fetchStamp: string):
                              BuildActionDef =
  ## The single action that materialises the vendored closure.
  ##
  ## Depends on the source fetch: `.cargo/config.toml` is written into the
  ## extracted tree, which does not exist until the source is unpacked.
  let vendorDir = cargoVendorDir(projectRoot)
  let cacheDir = cargoVendorCacheDir(projectRoot)
  let stamp = cargoVendorStampPath(projectRoot)
  let manifest = cargoVendorManifestPath(projectRoot)
  let configDir = cargoConfigDir(projectRoot)
  createDir(extendedPath(cargoVendorRoot(projectRoot)))

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  # ``sh`` is emitted as a bare token, not as an absolute path found here.
  # Tool resolution belongs to the engine, which satisfies the
  # ``toolIdentityRefs`` below from the store, from the cache, or from a
  # source build. Resolving it at emission time would make the action's
  # argv depend on the PATH of whichever process happened to expand the
  # graph, and would refuse to emit at all on a host that has not yet
  # realized its shell — which is precisely the host this tier exists to
  # serve.
  discard plan.len

  # A literal tab, bound once. Written inline it would be a raw tab in the
  # emitted script where no reader could see it, and `IFS` is the one place
  # in this loop where the difference between a tab and a space decides
  # whether every field parses.
  let tab = "\t"
  let forceLocal = when defined(windows): "--force-local " else: ""

  var script = "set -e; "
  script.add("mkdir -p \"" & q(cacheDir) & "\"; ")
  # Rebuilt from scratch: a stale crate directory left by a previous closure
  # would still satisfy cargo, and the build would succeed against a
  # dependency the manifest no longer names.
  script.add("rm -rf \"" & q(vendorDir) & "\"; ")
  script.add("mkdir -p \"" & q(vendorDir) & "\"; ")
  script.add("while IFS=\"" & tab & "\" read -r repro_url repro_sha " &
    "repro_dir; do ")
  script.add("case \"$repro_url\" in ''|'#'*) continue;; esac; ")
  script.add("repro_crate=\"" & q(cacheDir) & "/$repro_dir.crate\"; ")
  script.add("if [ ! -f \"$repro_crate\" ]; then ")
  script.add("curl -fsSL " & CurlFetchRetryArgs &
    " -o \"$repro_crate.part\" \"$repro_url\"; ")
  script.add("mv -f \"$repro_crate.part\" \"$repro_crate\"; fi; ")
  # Verified on every run, not only after a download: a cache entry
  # corrupted in place is exactly what this check exists to catch.
  script.add("printf '%s  %s\\n' \"$repro_sha\" \"$repro_crate\" | " &
    "sha256sum -c - > /dev/null; ")
  script.add("tar " & forceLocal & "-xf \"$repro_crate\" -C \"" &
    q(vendorDir) & "\"; ")
  script.add("printf '{\"files\":{},\"package\":\"%s\"}' \"$repro_sha\" > \"" &
    q(vendorDir) & "/$repro_dir/.cargo-checksum.json\"; ")
  script.add("done < \"" & q(manifest) & "\"; ")
  script.add("mkdir -p \"" & q(configDir) & "\"; ")
  var configText = ""
  for line in cargoVendorConfig(vendorDir).splitLines():
    if line.len == 0:
      configText.add("\\n")
    else:
      configText.add(line.replace("'", "'\\''") & "\\n")
  script.add("printf '%b' '" & configText & "' > \"" &
    q(configDir) & "/config.toml\"; ")
  script.appendVerifiedFetchStamp(stamp)

  var inputs: seq[string] = @[manifest]
  if fetchStamp.len > 0:
    inputs.insert(fetchStamp, 0)
  buildAction(
    id = cargoVendorActionId(packageName),
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    deps = if fetchActionId.len > 0: @[fetchActionId] else: @[],
    inputs = inputs,
    outputs = @[stamp],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cargo-vendor.crates-io",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = @["sh", "rm", "mkdir", "curl", "mv", "tar", "gzip",
      "sha256sum", "printf"])
