## M9.R.36.3 — verify the umask-022 wrap applies on BOTH the bypass and
## runquota helper-spawn / inline-runquota paths.
##
## M9.R.35.1 lifted ``umask 022`` into ``startBypassRunQuotaProcess`` to
## close a qmlcachegen mode-corruption channel (Qt6 ``QSaveFile`` ->
## ``QTemporaryFileEngine`` -> kernel umask-on-mkstemp drift producing
## ``.qmltypes`` / ``.cpp`` files at modes ``0300`` / ``0254`` / ``0044``
## / ``0204``, which then trip ``cc1plus: fatal error: Permission
## denied``).  The pin was bypass-only — a daemon-mode build that takes
## the runquota helper path forwarded ``command.argv`` straight through
## to the helper's ``launchProcess`` call site, leaving the umask drift
## channel intact.
##
## M9.R.36.3 factored ``umaskWrappedArgv`` out and applied it to BOTH
## the helper-spawn argv (via ``startRunQuotaProcess`` ->
## ``ReproCommandSpec.argv``) AND the inline-runquota batch path (via
## ``runQuotaCommand`` -> the staged ``commands[k]`` array consumed by
## ``offerWithRunQuotaBatch``).  This test pins:
##
##   1. ``umaskWrappedArgv`` emits the canonical ``/bin/sh -c "umask
##      022 && <quoted argv>"`` 3-element argv on POSIX.
##   2. The wrap is the identity transform on Windows (where umask
##      doesn't apply and ``/bin/sh`` isn't a host dep).
##   3. Each argv element is shell-quoted via ``quoteShell`` so a
##      tool name with spaces / glob chars survives the wrap.
##   4. Empty argv is preserved (identity transform).

import std/[strutils, unittest]

import repro_build_engine

suite "M9.R.36.3 umask-022 sh-wrap":
  test "POSIX wrap shape: 3-element /bin/sh -c argv":
    let wrapped = umaskWrappedArgv(@["echo", "hello"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2].startsWith("umask 022 && ")
      # Verify the wrapped command tail contains both argv elements,
      # quoted via quoteShell. We don't pin the exact quoting rules
      # because they differ per platform sub-shell, but the substrings
      # MUST survive verbatim.
      check "echo" in wrapped[2]
      check "hello" in wrapped[2]
    else:
      # Windows: identity.
      check wrapped == @["echo", "hello"]

  test "POSIX wrap shell-quotes spaces":
    let wrapped = umaskWrappedArgv(@["cc", "my file.c"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2].startsWith("umask 022 && ")
      # quoteShell on POSIX single-quotes elements with spaces.  Either
      # ``'my file.c'`` or escaped ``my\ file.c`` is acceptable; just
      # check the literal substring containing the space is preserved.
      check "my file.c" in wrapped[2]
    else:
      check wrapped == @["cc", "my file.c"]

  test "empty argv is identity":
    let wrapped = umaskWrappedArgv(@[])
    check wrapped.len == 0

  test "single-element argv is wrapped":
    let wrapped = umaskWrappedArgv(@["true"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2] == "umask 022 && true"
    else:
      check wrapped == @["true"]
