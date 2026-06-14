## C3 integration-test harness: small helper that exercises the real
## ``materializeSandboxManifest`` pipeline against a synthetic store
## layout the test driver pre-creates.
##
## Usage:
##   c3_manifest_emit
##     --catalog-root <dir>          # contains <distro>/<name>.json
##     --root-catalog <path>         # the package whose manifest we emit
##     --store-prefixes <key=path,>  # prefixesMap entries
##     --exec-path <abs-path>        # the wrapped binary's absolute path
##     --manifest-out <abs-path>     # where to write the manifest
##     [--shim-out <bin-dir>]        # if set, also emits per-binary
##                                   #   shims for execs discovered
##                                   #   under the root package's bin/
##                                   #   (so the test driver can run
##                                   #    the shim directly).
##     [--launcher-bin <abs-path>]   # required when --shim-out is set

import std/[os, strutils, tables]

import repro_local_store

proc parseKvList(s: string): seq[(string, string)] =
  ## "k=v,k=v" -> [(k,v), ...]
  for item in s.split(','):
    let t = item.strip()
    if t.len == 0: continue
    let idx = t.find('=')
    if idx < 0:
      stderr.writeLine "bad --store-prefixes entry (no '='): ", t
      quit(1)
    result.add((t[0 ..< idx], t[idx + 1 .. ^1]))

when isMainModule:
  var catalogRoot = ""
  var rootCatalog = ""
  var storePrefixesRaw = ""
  var execPath = ""
  var manifestOut = ""
  var shimOut = ""
  var launcherBin = ""

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    case a
    of "--catalog-root":     catalogRoot = paramStr(i+1); inc i, 2
    of "--root-catalog":     rootCatalog = paramStr(i+1); inc i, 2
    of "--store-prefixes":   storePrefixesRaw = paramStr(i+1); inc i, 2
    of "--exec-path":        execPath = paramStr(i+1); inc i, 2
    of "--manifest-out":     manifestOut = paramStr(i+1); inc i, 2
    of "--shim-out":         shimOut = paramStr(i+1); inc i, 2
    of "--launcher-bin":     launcherBin = paramStr(i+1); inc i, 2
    else:
      stderr.writeLine "unknown arg: ", a
      quit(1)

  if catalogRoot.len == 0 or rootCatalog.len == 0 or
     storePrefixesRaw.len == 0 or execPath.len == 0 or
     manifestOut.len == 0:
    stderr.writeLine "missing required flags"
    quit(1)

  var prefixes: PrefixesMap
  for (k, v) in parseKvList(storePrefixesRaw):
    prefixes[k] = v

  let closure = materializeSandboxManifest(
    rootCatalogPath = rootCatalog,
    catalogRoot = catalogRoot,
    prefixes = prefixes,
    execPath = execPath,
    outPath = manifestOut)

  stderr.writeLine "manifest emitted: ", manifestOut
  stderr.writeLine "closure size: ", closure.len
  for p in closure:
    stderr.writeLine "  - ", p.distro, "/", p.name

  if shimOut.len > 0:
    if launcherBin.len == 0:
      stderr.writeLine "--shim-out requires --launcher-bin"
      quit(1)
    # The "binary" we care about is whatever execPath points at; the
    # shim's filename is its basename.
    let name = extractFilename(execPath)
    let shimText = generateLauncherShim(name, execPath, manifestOut,
      launcherBin)
    createDir(shimOut)
    let shimPath = shimOut / name
    writeFile(shimPath, shimText)
    when not defined(windows):
      # chmod +x via stdlib
      import std/posix
      discard chmod(shimPath.cstring, S_IRWXU or S_IRGRP or S_IXGRP or
        S_IROTH or S_IXOTH)
    stderr.writeLine "shim emitted: ", shimPath
