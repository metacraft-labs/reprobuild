## `fs.userFile` driver — whole-file ownership at a `~`-relative
## `$HOME` path (M68 home-scope analogue of system-scope
## `fs.systemFile` from M69 Phase C).
##
## The driver owns the file in full: a fresh apply CREATES the file at
## the resolved host path; a re-apply with unchanged content is a
## cache-hit no-op via BLAKE3-256 digest comparison; an apply with
## changed content OVERWRITES the file atomically (via the
## `.repro.tmp` + rename pattern the M68 managed-block driver uses);
## a destroy direction removes the file.
##
## POSIX permissions: the `mode` field is a permission octal as a
## string (`"0600"`, `"0644"`, `"0755"`, ...). The driver parses it
## and applies the corresponding `FilePermission` set via
## `setFilePermissions` after the write. On Windows the mode is
## RECORDED in the audit binding (so `repro home plan` can display
## what the operator declared) but NOT applied — Windows uses file
## extensions for executable status, not POSIX permission bits.
##
## Atomic write: the rewritten bytes go to `<resolvedPath>.repro.tmp`
## first; only after the buffer flushes does the driver `moveFile`
## the tmp over the target. A crash mid-write leaves the original
## file intact and the `.repro.tmp` orphaned; a subsequent apply
## OVERWRITES that tmp (we open with `fmWrite` which truncates) so
## the orphan does not confuse the next run.
##
## M83 step 10: `contentFromCommand` extension. When the resource
## declares `contentFromCommand = @["age", "-d", "-i", id, src]`
## (mutually exclusive with the literal `content` field), the driver
## spawns the command via `osproc.startProcess` at apply time,
## captures stdout as the bytes to write, and reports stderr + exit
## code on non-zero exit. The command runs unelevated under the
## apply-time user (the same user whose `$HOME` the file lives
## under). An optional `cacheKey` opts in to skipping the command
## invocation when the recorded post-apply digest still matches the
## current on-disk digest AND the cacheKey + argv are unchanged.
## The empty cacheKey (the default) means "always re-run the
## command" — idempotent but slow.

import std/[os, osproc, streams, strutils]
from repro_core/paths import extendedPath
from repro_home_generations import Digest256

import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------

proc observeUserFile*(hostPath: string): ObservedState =
  ## Read the file at the resolved host path. The observed bytes are
  ## the whole file content; mode is NOT digest-relevant (the file
  ## body is the unit of drift — a mode-only change is intentionally
  ## NOT considered drift, mirroring the system-scope `fs.systemFile`
  ## driver's contract).
  if not fileExists(extendedPath(hostPath)):
    result.present = false
    result.digest = zeroDigest()
    return
  let content = readFile(extendedPath(hostPath))
  var raw = newSeq[byte](content.len)
  for i, ch in content:
    raw[i] = byte(ord(ch))
  result.present = true
  result.rawBytes = raw
  result.digest = digestOfBytes(raw)

# ---------------------------------------------------------------------------
# Mode parsing + application.
# ---------------------------------------------------------------------------

proc parseModeOctal*(mode: string): int =
  ## Parse a POSIX permission octal string ("0600", "0644", "0755",
  ## etc.) into the corresponding integer permission bits. Accepts
  ## the leading "0" prefix conventionally used by `chmod` operands;
  ## also accepts the bare form ("644"). Raises `ValueError` if the
  ## string is empty, has non-octal characters, or exceeds 4 octal
  ## digits.
  if mode.len == 0:
    raise newException(ValueError, "empty mode string")
  if mode.len > 4:
    raise newException(ValueError,
      "mode string '" & mode & "' too long (max 4 octal digits)")
  for c in mode:
    if c < '0' or c > '7':
      raise newException(ValueError,
        "mode string '" & mode & "' has non-octal digit '" & $c & "'")
  result = 0
  for c in mode:
    result = (result shl 3) or (ord(c) - ord('0'))

proc filePermissionsFromMode*(mode: string): set[FilePermission] =
  ## Convert a POSIX mode octal string into a Nim `FilePermission`
  ## set. Three octal digits drive (owner, group, other); each digit's
  ## three bits drive (read, write, exec).
  let bits = parseModeOctal(mode)
  result = {}
  # Owner bits (mask 0o700).
  if (bits and 0o400) != 0: result.incl(fpUserRead)
  if (bits and 0o200) != 0: result.incl(fpUserWrite)
  if (bits and 0o100) != 0: result.incl(fpUserExec)
  # Group bits (mask 0o070).
  if (bits and 0o040) != 0: result.incl(fpGroupRead)
  if (bits and 0o020) != 0: result.incl(fpGroupWrite)
  if (bits and 0o010) != 0: result.incl(fpGroupExec)
  # Other bits (mask 0o007).
  if (bits and 0o004) != 0: result.incl(fpOthersRead)
  if (bits and 0o002) != 0: result.incl(fpOthersWrite)
  if (bits and 0o001) != 0: result.incl(fpOthersExec)

# ---------------------------------------------------------------------------
# Command-stdout capture (M83 step 10 `contentFromCommand`).
# ---------------------------------------------------------------------------

type
  EUserFileCommand* = object of CatchableError
    ## Raised when `contentFromCommand` cannot be invoked or the
    ## command exits non-zero. The message names the resource +
    ## first argv element + exit code; the captured stderr is
    ## suffixed verbatim so the operator sees what failed.

proc runContentCommand*(argv: openArray[string]): seq[byte] =
  ## Spawn `argv` (no shell — passed verbatim to `startProcess`),
  ## stream stdout into the returned byte sequence, and raise
  ## `EUserFileCommand` on non-zero exit. The child inherits the
  ## parent environment + working directory; the parent's PATH is
  ## used to resolve `argv[0]` (`poUsePath`). Stderr is captured to
  ## a string buffer and surfaced via the raised exception on
  ## failure so the operator gets a clear diagnostic ("age: no
  ## identity matched any recipient" etc.). On success stderr is
  ## discarded — a successful run should not emit anything
  ## important on the error stream, and we do NOT want a chatty
  ## stderr to corrupt the digest stability.
  if argv.len == 0:
    raise newException(EUserFileCommand,
      "contentFromCommand requires at least the program name")
  if argv[0].len == 0:
    raise newException(EUserFileCommand,
      "contentFromCommand[0] (program name) must be non-empty")
  let prog = argv[0]
  var args: seq[string] = @[]
  if argv.len > 1:
    for i in 1 ..< argv.len:
      args.add(argv[i])
  # `poUsePath` resolves `prog` against the inherited PATH. No shell
  # interpretation — `args` are passed verbatim, so a shell
  # metacharacter in `src` / `identity` cannot escape the argument.
  # Omitting `poStdErrToStdOut` gives us separate stderr / stdout
  # streams (the default).
  var p: Process
  try:
    p = startProcess(prog, args = args, options = {poUsePath})
  except OSError as e:
    raise newException(EUserFileCommand,
      "contentFromCommand failed to spawn '" & prog & "': " & e.msg)
  except Exception as e:
    raise newException(EUserFileCommand,
      "contentFromCommand failed to spawn '" & prog & "': " & e.msg)
  var stdoutBytes: seq[byte] = @[]
  var stderrBuf = ""
  block:
    let outStream = p.outputStream()
    let errStream = p.errorStream()
    # Drain stdout into the result bytes + stderr into a string
    # buffer. `readAll` blocks until EOF — fine for the at-rest
    # secrets pattern (an `age -d` invocation is bounded in size).
    if outStream != nil:
      let raw = outStream.readAll()
      stdoutBytes = newSeq[byte](raw.len)
      for i, ch in raw:
        stdoutBytes[i] = byte(ord(ch))
    if errStream != nil:
      stderrBuf = errStream.readAll()
  let exitCode = p.waitForExit()
  p.close()
  if exitCode != 0:
    var msg = "contentFromCommand '" & prog & "' exited with " &
      $exitCode
    if stderrBuf.len > 0:
      msg.add(": ")
      msg.add(stderrBuf.strip())
    raise newException(EUserFileCommand, msg)
  result = stdoutBytes

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------

proc writeUserFileBytes*(hostPath: string;
                         payload: openArray[byte];
                         mode: string): seq[byte] =
  ## Write `payload` to `hostPath` atomically (tmp + rename), apply
  ## POSIX `mode` on POSIX hosts, re-probe via `observeUserFile`,
  ## and return the on-disk bytes. Shared low-level helper between
  ## the literal-content path (`applyUserFileResource`) and the
  ## `contentFromCommand` path (`applyUserFileResourceCmd`) so the
  ## atomic-write, mode-apply, and post-apply-reprobe contract is
  ## implemented once.
  let parent = parentDir(hostPath)
  if parent.len > 0:
    createDir(extendedPath(parent))
  let tmp = hostPath & ".repro.tmp"
  # Binary-mode write — bypass std/syncio.writeFile's CRLF translation
  # on Windows so the bytes on disk equal `payload` verbatim. Drift
  # detection compares BLAKE3-256 over the raw bytes; any translation
  # would produce constant false-positive drift on every re-apply.
  block:
    var f: File
    if not open(f, extendedPath(tmp), fmWrite):
      raise newException(IOError, "cannot open " & tmp)
    try:
      if payload.len > 0:
        discard f.writeBuffer(unsafeAddr payload[0], payload.len)
    finally:
      close(f)
  if fileExists(extendedPath(hostPath)):
    try: removeFile(extendedPath(hostPath)) except OSError: discard
  moveFile(extendedPath(tmp), extendedPath(hostPath))
  # Apply mode on POSIX; on Windows the field is recorded but not
  # enforced. An empty / unset mode string is a no-op.
  when not defined(windows):
    if mode.len > 0:
      try:
        let perms = filePermissionsFromMode(mode)
        setFilePermissions(extendedPath(hostPath), perms)
      except ValueError as e:
        raise newException(IOError,
          "fs.userFile '" & hostPath & "' has invalid mode '" & mode &
          "': " & e.msg)
  # Post-apply re-probe — re-read and verify the digest matches what
  # we wrote. Fails closed on mismatch.
  let post = observeUserFile(hostPath)
  let desired = digestOfBytes(payload)
  if not post.present or post.digest != desired:
    raise newException(IOError,
      "fs.userFile '" & hostPath & "' post-apply observation " &
      "disagrees with desired state: the filesystem write completed " &
      "but a re-read shows different bytes. The driver fails closed " &
      "rather than reporting a spurious success.")
  result = post.rawBytes

proc applyUserFileResource*(hostPath, content, mode: string): seq[byte] =
  ## Write the resource from a literal `content` string. Creates
  ## parent directories as needed, writes to a `.repro.tmp` sibling,
  ## then renames over the target. The returned bytes are exactly
  ## what was written (used by the manifest record as `payloadBytes`).
  ##
  ## POST-APPLY RE-PROBE (M82 Phase A contract): the apply path
  ## re-reads the file and asserts the digest equals
  ## `digestOfBytes(content)`. A mismatch raises `IOError`. The
  ## filesystem write is synchronous but a concurrent writer could
  ## corrupt the bytes between rename and return; re-reading closes
  ## that gap.
  var buf = newSeq[byte](content.len)
  for i, ch in content:
    buf[i] = byte(ord(ch))
  return writeUserFileBytes(hostPath, buf, mode)

proc applyUserFileResourceCmd*(hostPath: string;
                               argv: openArray[string];
                               mode: string;
                               cacheKey: string;
                               recordedPostDigest: Digest256;
                               hasRecordedPostDigest: bool): seq[byte] =
  ## M83 step 10: write the resource from the stdout of `argv`.
  ##
  ## When `cacheKey` is non-empty AND the previous generation
  ## recorded a `postWriteDigest` (`hasRecordedPostDigest = true`)
  ## AND the on-disk bytes still digest equal to that recorded
  ## value, skip the command invocation entirely and return the
  ## current on-disk bytes (the cache-hit short-circuit). Mode
  ## reconciliation is still performed on the existing file in
  ## that branch — a mode-only drift converges.
  ##
  ## When `cacheKey` is empty OR the recorded digest is missing OR
  ## the on-disk bytes have drifted, invoke `runContentCommand` to
  ## obtain the fresh stdout bytes and write them atomically via
  ## `writeUserFileBytes`.
  ##
  ## The returned bytes are exactly what is on disk after the call
  ## (used by the manifest record as `payloadBytes`).
  if cacheKey.len > 0 and hasRecordedPostDigest:
    let observed = observeUserFile(hostPath)
    if observed.present and observed.digest == recordedPostDigest:
      # Cache-hit: the on-disk bytes still match the recorded
      # post-apply digest. Skip the (potentially expensive)
      # command. Reconcile mode only — a mode-only drift becomes a
      # silent convergence here (the literal-content path has the
      # same semantics: the digest does not cover mode).
      when not defined(windows):
        if mode.len > 0:
          try:
            let perms = filePermissionsFromMode(mode)
            setFilePermissions(extendedPath(hostPath), perms)
          except ValueError as e:
            raise newException(IOError,
              "fs.userFile '" & hostPath & "' has invalid mode '" &
              mode & "': " & e.msg)
      return observed.rawBytes
  let captured = runContentCommand(argv)
  return writeUserFileBytes(hostPath, captured, mode)

proc destroyUserFileResource*(hostPath: string) =
  ## Remove the file. The driver owns the file in full; the destroy
  ## direction deletes it (`fs.systemFile`'s contract — no `--remove`
  ## flag needed on a whole-file owner). A missing file is a no-op
  ## (the lifecycle algorithm catches "destroy a thing that's not
  ## there" upstream; this guard is defence-in-depth).
  if fileExists(extendedPath(hostPath)):
    try: removeFile(extendedPath(hostPath)) except OSError: discard
  # Also clean a stray `.repro.tmp` if one happens to exist — a crash
  # between tmp-write and rename would leave one behind; this gives a
  # destroy direction a clean slate without orphaning the tmp.
  let tmp = hostPath & ".repro.tmp"
  if fileExists(extendedPath(tmp)):
    try: removeFile(extendedPath(tmp)) except OSError: discard
