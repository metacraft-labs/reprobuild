## Vendor-fetch action emitter for from-source Rust recipes.
##
## Sibling of ``fetch_action``. Where that one acquires the package's own
## source tarball, this one acquires the package's DEPENDENCY CLOSURE: every
## crate named by the committed vendor manifest, unpacked into a directory
## cargo can be pointed at instead of the network.
##
## ## Why a second acquisition step exists at all
##
## The ``.crate`` tarball a recipe fetches contains the package and nothing
## else. ``cargo build --offline`` needs every transitive dependency already
## on disk, so a from-source Rust recipe that stops at the source fetch is a
## recipe that cannot build without the network — which is the property the
## whole from-source tier exists to have.
##
## ## Why a manifest rather than a lockfile read
##
## The closure could be derived from the ``Cargo.lock`` inside the fetched
## source, but not HERE: graph emission happens before the fetch action has
## run, so at this point the lockfile does not exist. Deriving it later, at
## build time, would make the largest input to the build invisible to review
## and to the action fingerprint until the build was already running.
##
## So the recipe commits the closure beside itself, generated once from an
## upstream lockfile (see ``repro_core/cargo_lock``). This emitter reads that
## file at emission time, which is what lets the manifest's content reach the
## action's fingerprint: change a pinned dependency and the action re-runs.
##
## ## Shape of the emitted action
##
## One action, not one per crate. A closure of three to five hundred crates
## would otherwise be three to five hundred graph nodes whose only purpose is
## to land files in one directory — and on Windows the argv that would carry
## them exceeds what ``CreateProcess`` accepts long before that. The script
## is a fixed loop over the manifest:
##
##   1. ``curl`` the crate into a content-addressed cache path, skipping the
##      download when it is already there;
##   2. verify it against the manifest's SHA-256 — which came from the
##      lockfile, and is the only thing the download is checked against;
##   3. unpack it into ``<vendor>/<name>-<version>``, which is the directory
##      name cargo expects and also the top-level directory inside the
##      ``.crate`` tarball, so no strip is needed;
##   4. write the ``.cargo-checksum.json`` cargo requires beside it.
##
## Then the ``.cargo/config.toml`` that replaces both crates.io spellings
## with the vendored directory, and the stamp.
##
## The loop reads the manifest from disk rather than carrying it in the
## script, so the script stays a few hundred bytes whatever the closure's
## size. The manifest's DIGEST is folded into the stamp token by
## ``appendVerifiedFetchStamp``, because the script text it hashes includes
## the manifest path and this emitter refuses to emit at all when the file
## is missing or unreadable.
##
## Like ``fetch_action``, the action is non-cacheable: it reaches the network
## and has no monitorable file-dependency evidence. Its stamp short-circuits
## the work on a second run.

import std/[os, strutils]

import repro_core
import repro_core/cargo_lock
import repro_provider_runtime
import repro_project_dsl

const
  CargoVendorManifestName* = "cargo-vendor.manifest"
    ## The committed manifest's name, beside the recipe's ``repro.nim``.

  CargoVendorSubdir* = ".repro/cargo-vendor"
    ## Scratch root: the unpacked vendor tree and the crate download cache.
    ## Under ``.repro/`` so ``repro clean`` takes it with everything else.

proc cargoVendorManifestPath*(projectRoot: string): string =
  projectRoot / CargoVendorManifestName

proc cargoVendorRoot*(projectRoot: string): string =
  projectRoot / CargoVendorSubdir

proc cargoVendorDir*(projectRoot: string): string =
  ## Where the unpacked crates live — the directory ``.cargo/config.toml``
  ## points at.
  cargoVendorRoot(projectRoot) / "vendor"

proc cargoVendorCacheDir*(projectRoot: string): string =
  ## Where the downloaded ``.crate`` files live.
  ##
  ## Separate from the unpacked tree so a re-run that wipes the vendor
  ## directory does not re-download a closure it already has. The cache is
  ## keyed by crate directory name, which carries the version, so two
  ## versions of one crate never collide.
  cargoVendorRoot(projectRoot) / "crates"

proc cargoVendorStampPath*(projectRoot: string): string =
  cargoVendorRoot(projectRoot) / "vendor.stamp"

proc cargoConfigDir*(projectRoot: string): string =
  ## ``.cargo/`` beside the EXTRACTED SOURCE, not beside the recipe: cargo
  ## looks for configuration upward from the manifest directory it is
  ## building, and the recipe root is not on that path.
  projectRoot / "src" / ".cargo"

proc cargoVendorActionId*(packageName: string): string =
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
  ## Build the single action that materialises the vendored closure.
  ##
  ## Depends on the source fetch: ``.cargo/config.toml`` is written into the
  ## extracted tree, which does not exist until the source has been
  ## unpacked.
  let vendorDir = cargoVendorDir(projectRoot)
  let cacheDir = cargoVendorCacheDir(projectRoot)
  let stamp = cargoVendorStampPath(projectRoot)
  let manifest = cargoVendorManifestPath(projectRoot)
  let configDir = cargoConfigDir(projectRoot)
  createDir(extendedPath(cargoVendorRoot(projectRoot)))

  proc q(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")

  let shExe = findExe("sh")
  if shExe.len == 0:
    raise newException(CargoLockError,
      "from-source-cargo: the vendor step needs a POSIX shell and none " &
      "was found on PATH. Unlike the source fetch, this step has no " &
      "single-command fallback — it is a loop over " & $plan.len &
      " crates.")

  # A literal tab, bound once. Writing it inline would put a raw tab in the
  # emitted script where no reader could see it, and `IFS` is the one place
  # in this loop where the difference between a tab and a space decides
  # whether every field parses.
  let tab = "\t"
  let forceLocal = when defined(windows): "--force-local " else: ""

  var script = "set -e; "
  script.add("mkdir -p \"" & q(cacheDir) & "\"; ")
  # The vendor tree is rebuilt from scratch: a stale crate directory left by
  # a previous closure would still satisfy cargo, and the build would
  # succeed against a dependency the manifest no longer names.
  script.add("rm -rf \"" & q(vendorDir) & "\"; ")
  script.add("mkdir -p \"" & q(vendorDir) & "\"; ")
  script.add("while IFS=\"" & tab & "\" read -r repro_url repro_sha " &
    "repro_dir; do ")
  script.add("case \"$repro_url\" in ''|'#'*) continue;; esac; ")
  script.add("repro_crate=\"" & q(cacheDir) & "/$repro_dir.crate\"; ")
  # Download only what is missing. The cache is keyed by <name>-<version>,
  # so a hit is a hit on exactly the crate the manifest names.
  script.add("if [ ! -f \"$repro_crate\" ]; then ")
  script.add("curl -fsSL " & CurlFetchRetryArgs &
    " -o \"$repro_crate.part\" \"$repro_url\"; ")
  script.add("mv -f \"$repro_crate.part\" \"$repro_crate\"; fi; ")
  # Verified on every run, not only after a download: a cache entry that
  # was corrupted in place is exactly what this check exists to catch.
  script.add("printf '%s  %s\\n' \"$repro_sha\" \"$repro_crate\" | " &
    "sha256sum -c - > /dev/null; ")
  # A .crate is a gzipped tar whose single top-level directory is
  # <name>-<version>, so extracting into the vendor root lands it at the
  # name cargo expects with no strip.
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

  result = buildAction(
    id = cargoVendorActionId(packageName),
    call = inlineExecCall(@[shExe, "-c", script], projectRoot),
    deps = if fetchActionId.len > 0: @[fetchActionId] else: @[],
    inputs = if fetchStamp.len > 0: @[fetchStamp, manifest] else: @[manifest],
    outputs = @[stamp],
    pool = "fetch",
    # Non-cacheable for the reason the source fetch is: the step reaches
    # the network and has no monitorable file-dependency evidence. The
    # stamp is what short-circuits it on a second run.
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cargo-vendor.crates-io",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = @["sh", "rm", "mkdir", "curl", "mv", "tar", "gzip",
      "sha256sum", "printf"])
