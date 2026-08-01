import std/[os, osproc, strtabs]

proc main() =
  ## Count one spawn, then forward the original argv to the real repro binary.
  let counter = getEnv("REPRO_M76_SHIM_COUNTER")
  let target = getEnv("REPRO_M76_SHIM_TARGET")
  if counter.len > 0:
    var f: File
    if open(f, counter, fmAppend):
      f.write(".")
      f.close()
  if target.len == 0:
    quit("shim: REPRO_M76_SHIM_TARGET not set", 1)

  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    args.add(paramStr(i))

  var envCopy = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    envCopy[k] = v

  var p = startProcess(target, args = args, env = envCopy,
    options = {poParentStreams})
  let rc = p.waitForExit()
  p.close()
  quit(rc)

main()
