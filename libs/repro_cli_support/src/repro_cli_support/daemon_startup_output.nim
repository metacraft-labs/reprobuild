## Nonblocking, bounded diagnostics from invocation-owned POSIX daemons.
## Drain both pipes while waiting for readiness: reading only after exit can
## deadlock a child whose refusal fills either pipe before it can exit.
import std/[os, strutils]
import std/posix

const startupOutputLimit = 64 * 1024

type StartupOutput* = object
  text: string
  truncated: bool

proc prepareStartupOutput*(fd: cint) =
  ## Make the read end nonblocking without changing its other file flags.
  let flags = fcntl(fd, F_GETFL)
  if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError(), "cannot capture runquotad startup output")

proc drainStartupOutput*(output: var StartupOutput; fd: cint) =
  ## A finite drain also bounds work if a broken child writes continuously.
  ## Retain the tail: the refusal is generally the last thing a daemon says.
  var buffer: array[4096, char]
  var remaining = 256 * 1024
  while remaining > 0:
    let count = posix.read(fd, addr buffer[0], buffer.len)
    if count <= 0:
      if count < 0 and errno == EINTR:
        continue
      return
    remaining -= int(count)
    let oldLen = output.text.len
    output.text.setLen(oldLen + int(count))
    copyMem(addr output.text[oldLen], addr buffer[0], int(count))
    if output.text.len > startupOutputLimit:
      output.text = output.text[^startupOutputLimit .. ^1]
      output.truncated = true

proc startupDiagnostic*(output: StartupOutput; label: string): string =
  ## Label retained output and disclose any bytes excluded by the bound.
  if output.text.len > 0:
    result = "\nrunquotad " & label & ":\n" &
      (if output.truncated: "[truncated; last 65536 bytes]\n" else: "") &
      output.text.strip(leading = false)

const hostOwnerRefusalMarker* = "configured daemon owner uid "
  ## The words `runquota_ipc.inspectPath` puts in front of the uid the HOST
  ## endpoint policy expects (`rendezvousPolicy`: `RUNQUOTA_ENDPOINT_OWNER_UID`,
  ## else the `runquota` account). A private policy never names an owner other
  ## than the effective caller, so a refusal that names a different one was
  ## produced by the host policy. Matching a sibling's wording is held honest
  ## by `t_auto_runquota_uses_private_endpoint_policy.nim`, which provokes the
  ## refusal from the real daemon rather than from a copy of this string.

proc hostOwnerRefusalUid*(output: StartupOutput): int64 =
  ## The daemon owner uid a host-policy endpoint refusal named in `output`,
  ## or -1 when the output carries no such refusal. The last occurrence wins:
  ## the refusal is the last thing a daemon says before it exits.
  let at = output.text.rfind(hostOwnerRefusalMarker)
  if at < 0:
    return -1
  var digits = ""
  for ch in output.text[at + hostOwnerRefusalMarker.len .. ^1]:
    if ch notin Digits:
      break
    digits.add ch
  if digits.len == 0 or digits.len > 18:
    return -1
  int64(parseBiggestInt(digits))
