## M68 home-scope follow-up gate: integration_fs_user_file_apply.
##
## End-to-end exercise of the `fs.userFile` driver — the M68 home-scope
## analogue of system-scope `fs.systemFile` (M69 Phase C). Drives the
## full home-apply path: a profile declares a `fs.userFile` stanza, the
## intent parser recognizes it, the apply pipeline dispatches to the
## driver, the driver writes the file via the atomic-write pattern, and
## the lifecycle algorithm cache-hits on a re-apply with unchanged
## content, overwrites on a content change, and (on POSIX) applies the
## declared mode.
##
## This gate is intentionally driver-pure: it does NOT route through
## `repro home apply` (the CLI shell-out belongs to the home-apply gate
## suite). It uses the same in-process composition path
## `repro home apply` calls — `composeDesiredResources` +
## `composePlan` + the driver — but skips the launcher / store /
## manifest machinery that does not change for a `fs.userFile`-only
## profile.
##
## No `skip`, no `xfail` — runs on every host. The mode-application
## assertions are POSIX-only (guarded by `when not defined(windows)`);
## on Windows the mode field is recorded but the driver is a no-op for
## permission bits, so the Windows arm asserts presence and content
## only.

import std/[os, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_generations
import repro_home_intent
import repro_home_resources

const HostIdentity = "m68-fs-user-file-gate-host"

proc writeProfile(body: string): tuple[profileDir, profilePath: string] =
  ## Materialize a `home.nim` under a per-pid temp directory. The
  ## test uses `createTempDir`, which already encodes the pid into
  ## the dir name (matching the M82 Phase C tests' pattern); no
  ## further uniqueness work is needed for parallel invocations.
  let dir = createTempDir("repro-m68-fs-user-file-", "")
  let path = dir / "home.nim"
  writeFile(extendedPath(path), body)
  result = (profileDir: dir, profilePath: path)

proc fakeHomeDir(): string =
  ## A per-test `$HOME` root under the temp directory. We do NOT
  ## point at the real user's `$HOME` — the gate creates files at
  ## `<homeRoot>/.something` paths and cleans up afterwards.
  result = createTempDir("repro-m68-fs-user-file-home-", "")

proc applyOnce(profileText, homeRoot: string;
               recorded: var OrderedTable[string, RecordedBinding]):
    seq[ResourceBinding] =
  ## Drive the apply path the smallest distance that still exercises
  ## the driver: parse the profile, compose the desired set, observe
  ## the world, decide the action, run the driver, and return the
  ## emitted resource bindings. The caller-supplied `recorded` table
  ## carries previous-generation bindings between calls so the
  ## lifecycle algorithm can produce `update` rather than
  ## `drift_blocked` on a content change.
  let (dir, path) = writeProfile(profileText)
  defer:
    try: removeDir(extendedPath(dir)) except CatchableError: discard
  let profile = loadProfile(path)
  let desired = composeDesiredResources(profile, homeRoot, HostIdentity)
  let plan = composePlan(desired, recorded)
  for action in plan.actions:
    case action.kind
    of rakCreate, rakUpdate, rakReplace:
      let r = desired.resources[action.address]
      if r.kind == rkFsUserFile:
        let identity = realWorldIdentity(r)
        let preWrite = observeResource(r)
        let postBytes = applyUserFileResource(r.userFileHostPath,
          r.userFileContent, r.userFileMode)
        let rb = toResourceBinding(action.address, r.kind, identity,
          preWrite, postBytes, "user-file", r.lifecyclePolicy)
        result.add(rb)
        # Roll the binding into `recorded` so the next call's
        # lifecycle decision sees this generation's post-write digest.
        recorded[action.address] = toRecorded(rb)
    else: discard

proc applyOnce(profileText, homeRoot: string): seq[ResourceBinding] =
  ## Single-shot apply for tests that don't need to thread recorded
  ## bindings across calls.
  var recorded = initOrderedTable[string, RecordedBinding]()
  applyOnce(profileText, homeRoot, recorded)

# ---------------------------------------------------------------------------
# Scenarios.
# ---------------------------------------------------------------------------

suite "M68 gate: integration_fs_user_file_apply":

  test "fresh apply writes the file with declared content":
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    # The `home.nim` parser preserves the RHS string verbatim — it
    # strips a surrounding pair of `"` and unescapes `\"` / `\\` only
    # (no `\n` interpretation). Single-line content keeps the test
    # focused on driver behavior rather than DSL escape semantics.
    let body = """
import repro/profile

profile "m68-fs-user-file":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile gpgConf:
      hostFile = "~/.gnupg/gpg.conf"
      content = "default-key F8A8039154D5E989 keyserver hkps://keys.openpgp.org"
      mode = "0600"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    let bindings = applyOnce(body, homeRoot)
    check bindings.len == 1
    let target = homeRoot / ".gnupg" / "gpg.conf"
    check fileExists(extendedPath(target))
    let expectedContent =
      "default-key F8A8039154D5E989 keyserver hkps://keys.openpgp.org"
    check readFile(extendedPath(target)) == expectedContent
    # The binding's realWorldIdentity equals the resolved path. We
    # normalize separators because the resolver returns the value
    # `homeDir & hostFile[1..^1]` verbatim (`/` from the DSL side
    # joined with `\` from `getTempDir()` on Windows). Both denote
    # the same file — the comparison is normalization-equivalent.
    check bindings[0].realWorldIdentity.replace('\\', '/') ==
      target.replace('\\', '/')
    check bindings[0].resourceKind == "fs.userFile"
    check bindings[0].payloadKind == "user-file"

  test "re-apply with unchanged content is a no-op":
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    let body = """
import repro/profile

profile "m68-fs-user-file-noop":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "~/.config/repro/stable.txt"
      content = "stable content"
      mode = "0644"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    # First apply: create.
    var recorded = initOrderedTable[string, RecordedBinding]()
    discard applyOnce(body, homeRoot, recorded)
    let target = homeRoot / ".config" / "repro" / "stable.txt"
    check fileExists(extendedPath(target))
    let firstContent = readFile(extendedPath(target))
    # Second apply with the same content. The plan must classify the
    # action as `no-op` (which `applyOnce` does not act on), so no
    # binding is emitted by the driver branch. The recorded table
    # carries the first-apply binding so the lifecycle decision sees
    # `observed.digest == recorded.postWriteDigest`.
    let secondBindings = applyOnce(body, homeRoot, recorded)
    check secondBindings.len == 0
    # The file content is unchanged.
    check readFile(extendedPath(target)) == firstContent

  test "re-apply with changed content overwrites and post-probes":
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    let bodyV1 = """
import repro/profile

profile "m68-fs-user-file-overwrite":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "~/.config/repro/overwrite.txt"
      content = "version 1"
      mode = "0644"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    let bodyV2 = """
import repro/profile

profile "m68-fs-user-file-overwrite":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "~/.config/repro/overwrite.txt"
      content = "version 2 - much different"
      mode = "0644"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    var recorded = initOrderedTable[string, RecordedBinding]()
    discard applyOnce(bodyV1, homeRoot, recorded)
    let target = homeRoot / ".config" / "repro" / "overwrite.txt"
    check readFile(extendedPath(target)) == "version 1"
    let bindings = applyOnce(bodyV2, homeRoot, recorded)
    check bindings.len == 1
    check readFile(extendedPath(target)) == "version 2 - much different"

  test "executable shorthand defaults mode to 0755 when mode is absent":
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    let body = """
import repro/profile

profile "m68-fs-user-file-exec":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile wrapper:
      hostFile = "~/.local/bin/repro-wrapper"
      content = "#!/usr/bin/env bash"
      executable = true

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    discard applyOnce(body, homeRoot)
    let target = homeRoot / ".local" / "bin" / "repro-wrapper"
    check fileExists(extendedPath(target))
    when not defined(windows):
      let perms = getFilePermissions(target)
      check fpUserExec in perms
      check fpUserRead in perms
      check fpUserWrite in perms

  when not defined(windows):
    test "POSIX: declared mode 0600 is applied to the file":
      let homeRoot = fakeHomeDir()
      defer:
        try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
      let body = """
import repro/profile

profile "m68-fs-user-file-mode":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile secret:
      hostFile = "~/.secret-blob"
      content = "ssss"
      mode = "0600"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
      discard applyOnce(body, homeRoot)
      let target = homeRoot / ".secret-blob"
      check fileExists(target)
      let perms = getFilePermissions(target)
      check fpUserRead in perms
      check fpUserWrite in perms
      check fpUserExec notin perms
      check fpGroupRead notin perms
      check fpOthersRead notin perms

  when defined(windows):
    test "Windows: mode field accepted but not enforced":
      let homeRoot = fakeHomeDir()
      defer:
        try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
      let body = """
import repro/profile

profile "m68-fs-user-file-win":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "~/.config/repro/win-mode.txt"
      content = "windows test"
      mode = "0600"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
      # On Windows the mode is recorded in the binding but does not
      # touch the filesystem ACLs (Windows uses extensions for
      # executable status). The contract: apply succeeds, the file
      # exists with the declared content.
      discard applyOnce(body, homeRoot)
      let target = homeRoot / ".config" / "repro" / "win-mode.txt"
      check fileExists(extendedPath(target))
      check readFile(extendedPath(target)) == "windows test"

  test "${HOME} prefix expands to the home root":
    # The home-scope analogue of `fs.systemFile`'s `${PROGRAMDATA}`
    # support: `${HOME}` is an explicit way to write a $HOME-relative
    # path without the `~` shorthand. Both forms must resolve
    # identically.
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    let body = """
import repro/profile

profile "m68-fs-user-file-homevar":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "${HOME}/.config/repro/homevar.txt"
      content = "expanded"
      mode = "0644"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    discard applyOnce(body, homeRoot)
    let target = homeRoot / ".config" / "repro" / "homevar.txt"
    check fileExists(extendedPath(target))
    check readFile(extendedPath(target)) == "expanded"

  test "atomic-write: prior crash leaves no stale .repro.tmp":
    # Simulate the recovery path: pretend a previous apply crashed
    # mid-write — a `.repro.tmp` orphan sits where the target would
    # land but no real file is there. The next apply opens the tmp
    # with fmWrite (truncate) and renames it over the target, so the
    # orphan does not persist.
    let homeRoot = fakeHomeDir()
    defer:
      try: removeDir(extendedPath(homeRoot)) except CatchableError: discard
    let target = homeRoot / ".config" / "repro" / "atomic.txt"
    createDir(extendedPath(homeRoot / ".config" / "repro"))
    writeFile(extendedPath(target & ".repro.tmp"), "PARTIAL JUNK")
    let body = """
import repro/profile

profile "m68-fs-user-file-atomic":

  activity default:
    m68-fs-user-file-fixture

  resources:
    fs.userFile cfg:
      hostFile = "~/.config/repro/atomic.txt"
      content = "recovered"
      mode = "0644"

  hosts:
    "m68-fs-user-file-gate-host": [default]
"""
    discard applyOnce(body, homeRoot)
    check fileExists(extendedPath(target))
    check readFile(extendedPath(target)) == "recovered"
    check not fileExists(extendedPath(target & ".repro.tmp"))
