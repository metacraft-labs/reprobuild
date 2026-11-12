## Process-environment settings that undo themselves.
##
## A fixture that points a variable at its scratch directory (a private
## `TMPDIR`, a scratch certificate store) leaves the process naming a
## directory the case deletes when it ends. A grouped test binary runs many
## cases in one process, so every later case inherits it. A `ScopedEnv` held
## by the fixture restores each variable it set, unset ones staying unset,
## when the last copy of it is gone: at the end of the case, on every exit
## path, without a teardown line in each caller.
##
## It is a `ref`, so copying a fixture that holds one (into a closure, into
## another fixture) shares it rather than restoring twice; the restore runs
## once, when the last holder goes out of scope.
##
## SCOPES MAY END IN ANY ORDER. Each variable keeps a stack of the values the
## live scopes set, over the value it had before the first of them. A scope
## that ends on top restores the value below it (the next live scope's, or
## the original); one that ends under another only leaves the stack, because
## the scope above still holds the variable. Restoring the value it saw
## instead, which is right only when scopes end in reverse order, is wrong
## the moment they do not: assigning a new fixture over a live one ends the
## old scope AFTER the new one set the variable, and the old scope's restore
## would put the original back under the new fixture, pointing it at the
## user's own certificate store.

import std/[os, tables]

type
  ScopedEnvObj = object
    id: int
    names: seq[string]
  ScopedEnv* = ref ScopedEnvObj

  VariableLayers = object
    existed: bool         ## the variable was set before the first live scope
    original: string      ## and had this value
    layers: seq[tuple[scope: int; value: string]]
      ## the live scopes that set it, oldest first

var liveLayers: Table[string, VariableLayers]
var lastScopeId: int

proc release(name: string; scope: int) =
  ## End `scope`'s hold on `name` (see the module comment).
  if name notin liveLayers:
    return
  var entry = liveLayers.getOrDefault(name)
  var at = -1
  for i in countdown(entry.layers.high, 0):
    if entry.layers[i].scope == scope:
      at = i
      break
  if at < 0:
    return
  let onTop = at == entry.layers.high
  entry.layers.delete(at)
  if onTop:
    try:
      if entry.layers.len > 0: putEnv(name, entry.layers[^1].value)
      elif entry.existed: putEnv(name, entry.original)
      else: delEnv(name)
    except OSError:
      discard
  if entry.layers.len == 0:
    liveLayers.del(name)
  else:
    liveLayers[name] = entry

proc `=destroy`(env: ScopedEnvObj) =
  {.cast(gcsafe).}:
    for i in countdown(env.names.high, 0):
      try:
        release(env.names[i], env.id)
      except CatchableError:
        discard
  `=destroy`(env.names)

proc scopedEnv*(settings: openArray[tuple[name, value: string]]): ScopedEnv =
  ## Set every `(name, value)` in this process now, and restore what each
  ## variable was when the result's last holder goes out of scope.
  inc lastScopeId
  result = ScopedEnv(id: lastScopeId)
  for (name, value) in settings:
    if name notin liveLayers:
      liveLayers[name] = VariableLayers(existed: existsEnv(name),
        original: getEnv(name))
    var entry = liveLayers.getOrDefault(name)
    entry.layers.add((scope: result.id, value: value))
    liveLayers[name] = entry
    result.names.add(name)
    putEnv(name, value)
