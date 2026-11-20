## Environment tables for child processes, with the host's name semantics.
##
## Windows environment variable names are case-insensitive, and the inherited
## search path is normally spelled ``Path``
## (https://learn.microsoft.com/en-us/windows/win32/procthread/environment-variables).
## A copy of the inherited environment kept in a case-SENSITIVE table, followed
## by ``env["PATH"] = …``, therefore holds two entries for one variable. The
## child's environment block then carries both, and which one it reads depends
## on the order the block was written in: the value the caller set can be
## silently dropped. POSIX names are case-sensitive, so the distinction is kept
## there.
##
## Every place that copies the inherited environment, or builds a table that
## is later read or written by a fixed variable name, builds it here instead of
## repeating ``when defined(windows): modeCaseInsensitive`` per call site.
##
## Each proc takes ``caseInsensitive`` (default: the host's semantics) so the
## Windows behaviour can be exercised by a test on any host.

import std/[os, strtabs, strutils]

const HostEnvNamesAreCaseInsensitive* = defined(windows)
  ## Whether this host compares environment variable names case-insensitively.

proc envNameMode*(caseInsensitive = HostEnvNamesAreCaseInsensitive):
    StringTableMode =
  ## The ``strtabs`` mode that matches the requested name semantics.
  ## ``modeCaseInsensitive`` compares ASCII letters without case and nothing
  ## else, which is what Windows does for variable names
  ## (``modeStyleInsensitive`` would also ignore ``_`` and is never right).
  if caseInsensitive: modeCaseInsensitive else: modeCaseSensitive

proc newEnvTable*(caseInsensitive = HostEnvNamesAreCaseInsensitive):
    StringTableRef =
  ## An empty environment table with the requested name semantics.
  newStringTable(envNameMode(caseInsensitive))

proc envTableFrom*(pairs: openArray[(string, string)];
                   caseInsensitive = HostEnvNamesAreCaseInsensitive):
    StringTableRef =
  ## A table holding ``pairs``. When two entries name the same variable under
  ## the requested semantics (an environment block can carry both ``Path``
  ## and ``PATH``), the EARLIER one wins, name and value: a lookup in the
  ## block itself returns the first match (``GetEnvironmentVariableW`` and
  ## the CRT's ``_wgetenv`` scan it in order, as POSIX ``getenv`` does), so
  ## the table agrees with what ``getEnv`` reports in this process.
  ## Overrides are applied afterwards with ``[]=``, which replaces only the
  ## value and keeps the first spelling, so an inherited ``Path`` stays
  ## ``Path``.
  result = newEnvTable(caseInsensitive)
  for (name, value) in pairs:
    if not result.hasKey(name):
      result[name] = value

proc inheritedEnvTable*(caseInsensitive = HostEnvNamesAreCaseInsensitive):
    StringTableRef =
  ## A copy of this process's environment with the requested name semantics
  ## (duplicates resolved as ``envTableFrom`` does).
  var pairs: seq[(string, string)]
  for name, value in envPairs():
    pairs.add((name, value))
  envTableFrom(pairs, caseInsensitive)

proc sameEnvName*(a, b: string;
                  caseInsensitive = HostEnvNamesAreCaseInsensitive): bool =
  ## Whether ``a`` and ``b`` name the same variable under the requested
  ## semantics.
  if caseInsensitive: cmpIgnoreCase(a, b) == 0 else: a == b

proc prependPathEntry*(env: StringTableRef; entry: string;
                       name = "PATH") =
  ## Put ``entry`` in front of the search-path list ``name`` held in ``env``
  ## (``PathSep``-separated), or make it the whole list when ``env`` has none.
  ## The existing value is read from ``env`` itself, not from this process, so
  ## the result follows the table's own name semantics: in a case-insensitive
  ## table the inherited ``Path`` is found and extended in place.
  let current = env.getOrDefault(name)
  env[name] = if current.len > 0: entry & $PathSep & current else: entry

const LoaderControlEnvNames* = [
  "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "LD_DEBUG", "LD_DEBUG_OUTPUT",
  "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"]
  ## Every variable through which a caller can make the dynamic loader put
  ## something into, or say something about, a child it did not build: the
  ## search paths (``LD_LIBRARY_PATH``, both ``DYLD_*_LIBRARY_PATH``s), the
  ## injected objects (``LD_PRELOAD``, ``LD_AUDIT``, ``DYLD_INSERT_LIBRARIES``)
  ## and the loader's own tracing (``LD_DEBUG``, ``LD_DEBUG_OUTPUT``).
  ## See https://man7.org/linux/man-pages/man8/ld.so.8.html and dyld(1).

proc dropLoaderControls*(env: StringTableRef) =
  ## Remove every ``LoaderControlEnvNames`` entry from ``env`` in place.
  ##
  ## For the environment of a HOST tool the engine resolves off ``PATH`` for
  ## its own work (the distribution's ``git``, ``curl``, ``nix``). Such a tool
  ## was linked against the host's own libraries. A caller running inside a
  ## Nix dev shell or a provisioned profile can carry an ``LD_LIBRARY_PATH``
  ## that names libraries built against a newer glibc; a host binary that
  ## inherits it loads those in place of its own and dies before doing any
  ## work (``version `GLIBC_2.38' not found``). Tracing is dropped too: an
  ## inherited ``LD_DEBUG`` buries the child's one diagnostic line under the
  ## loader's trace, and ``LD_DEBUG_OUTPUT`` makes it write files wherever
  ## the caller pointed it.
  ##
  ## Only ``env`` changes; this process's own environment is untouched. The
  ## cost is accepted deliberately: a host tool that itself needs one of these
  ## variables to start (a hand-built binary under ``/opt``) no longer starts
  ## from here.
  if env.isNil:
    return
  for name in LoaderControlEnvNames:
    if env.hasKey(name):
      env.del(name)
