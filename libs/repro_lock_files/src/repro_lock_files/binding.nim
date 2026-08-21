## `--lock` — one flag, two forms, distinguished by `=`.
##
## Named-Lock-Files NLF-M7, design §5.1 and §5.2.
##
## > **One flag, not two.** `--lock` is the existing whole-build flag (§2.3)
## > generalised: with an `=` it binds a named lock file, without one it binds
## > `default`. A separate `--lock-file` flag alongside `--lock` would be two
## > spellings for one concept, which §2.3 warns against.
##
## Three properties this module exists to hold, each of which is a corpus case:
##
##   * **NLF-CLI-1** — one file, several names, one set of actions:
##     `--lock hostTools,targetRuntime=locks/native.lock` binds both. Under
##     §6.2 that costs nothing, "both names resolve to one lock file's content,
##     so one set of artifacts is built and shared".
##   * **NLF-CLI-2** — binding an undeclared name is an **error**, not a silent
##     no-op, "symmetrically with §4.9, and for the same reason: a mistyped
##     `--lock hostTool=…` that was quietly ignored would produce a green build
##     of the wrong thing".
##   * **NLF-CLI-4** — two bindings for `default` in one invocation "is an
##     error, not a precedence puzzle". Including the case where one of them
##     arrived through the bare `--lock <path>` form, since §5.2 says that form
##     "is exactly `--lock default=<path>`" and an implementation that treated
##     them as different flags would let the pair through.

import std/[algorithm, strutils, tables]

import ./declarations

type
  LockBindings* = object
    ## The name → path assignments for one invocation.
    byName*: Table[string, string]
    order*: seq[string]
      ## Names in the order they were bound, so a diagnostic can name the
      ## FIRST binding of a duplicated name rather than an arbitrary one.

proc initLockBindings*(): LockBindings =
  LockBindings(byName: initTable[string, string](), order: @[])

proc boundNames*(b: LockBindings): seq[string] =
  result = @[]
  for n in b.order: result.add(n)
  result.sort()

proc bindLockFile*(b: var LockBindings; name, path: string) =
  ## Bind one name. Raises on a second binding of the same name (NLF-CLI-4)
  ## and on an undeclared name (NLF-CLI-2).
  if not isDeclaredLockFile(name):
    var msg = "unknown lock file `" & name & "`\n" &
      "  --lock " & name & "=" & path & "\n" &
      "  no lock file with that name is declared in this workspace.\n\n" &
      "  in scope here:\n"
    for line in inScopeListingLines():
      msg.add(line & "\n")
    let suggestion = suggestLockFileName(name)
    if suggestion.len > 0:
      msg.add("\n  did you mean `" & suggestion & "`?\n")
    raise newException(LockFileError, msg)
  if b.byName.hasKey(name):
    raise newException(LockFileError,
      "lock file `" & name & "` is bound twice in one invocation\n" &
      "  first:  " & b.byName[name] & "\n" &
      "  second: " & path & "\n" &
      "  this is an error rather than a precedence puzzle; pass one " &
      "binding per name.")
  b.byName[name] = path
  b.order.add(name)

proc applyLockFlag*(b: var LockBindings; value: string) =
  ## Apply one `--lock` occurrence.
  ##
  ## §5.2: "The two forms are distinguished by the presence of `=`." A value
  ## with no `=` is `--lock default=<value>` — the existing whole-build
  ## spelling, retained and NOT deprecated.
  ##
  ## The split is on the FIRST `=`, so a path containing `=` still binds
  ## correctly once a name precedes it, and a bare path containing `=` is the
  ## one ambiguity the grammar has. It resolves toward the named form, which
  ## is the safe direction: the named form validates the name against the
  ## declarations and therefore ERRORS on a path misread as a name, while the
  ## reverse mistake would silently bind `default` to a path that is not one.
  let eq = value.find('=')
  if eq < 0:
    b.bindLockFile(DefaultLockFileName, value)
    return
  let namePart = value[0 ..< eq]
  let path = value[eq + 1 .. ^1]
  for raw in namePart.split(','):
    let name = raw.strip()
    if name.len == 0: continue
    b.bindLockFile(name, path)

proc resolvedPathFor*(b: LockBindings; name: string): string =
  ## §5.3's resolution for one name under these bindings.
  resolveLockFilePath(name, b.byName)
