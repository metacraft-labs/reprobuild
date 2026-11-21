## How a printed remedy spells a path.
##
## Spec: Unified-Locking-And-Hooks.md §"The named command must RUN where the
## message is printed", rule 3 ("Quote for the shell the hooks run in"). The
## managed hooks run under a POSIX `sh` on every host, Git's own on Windows,
## and an operator pastes a remedy into that shell. So each path in a remedy
## is ONE word of a POSIX shell whatever host printed it, and on Windows it is
## spelled with `/` separators, so one message spells every path one way.
##
## ``quoteShell`` is the wrong tool for this: it quotes for the HOST that
## prints the message, and on Windows it leaves `M:\m\ws` unquoted, which `sh`
## reads as `M:mws`. A command the code EXECUTES keeps host quoting; only a
## command the operator is told to run goes through here.
##
## These live in `repro_core` so that every library that prints a remedy —
## `repro_cli_support`, `repro_workspace_vcs`, `repro_workspace_manifests` —
## spells it the same way. `repro_cli_support/lock_consistency` re-exports
## them.

import std/[os, strutils]

proc remedyProsePath*(path: string; windowsHost = defined(windows)): string =
  ## ``path`` as the PROSE around a remedy names it ("From <root> run: …",
  ## "(checkout <path>)"): not quoted, because it is not pasted, but spelled
  ## with the separators ``remedyPathWord`` gives the commands beside it, so
  ## one message spells a path one way on Windows.
  if windowsHost: path.replace('\\', '/') else: path

proc remedyPathWord*(path: string; windowsHost = defined(windows)): string =
  ## ``path`` as ONE word of a remedy the operator pastes into the shell the
  ## managed hooks run under — `sh`, Git's own on Windows — so it is quoted
  ## for a POSIX shell on every host, and spelled with `/` on Windows.
  ##
  ## Every remedy path goes through here; a remedy that quotes one path with
  ## ``quoteShell`` and its neighbour with this spells them two ways on
  ## Windows and leaves the first broken in `sh`.
  quoteShellPosix(remedyProsePath(path, windowsHost))
