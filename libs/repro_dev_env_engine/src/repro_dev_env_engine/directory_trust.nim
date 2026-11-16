## Directory trust for dev-env activation.
##
## An allow record binds a project root to a digest of its *recipe closure*:
## the project file, the local Nim modules it imports or includes (found
## textually, transitively, below the project root), the dev-env lock slice
## and the develop-overrides file. Pulling or checking out a change to any of
## them makes the root untrusted again until `repro allow` is re-run, the way
## direnv blocks a changed `.envrc`.
##
## Both the full `repro dev-env export` and the prompt-time fast path call
## `directoryTrustState`, and so must every other implicit activation (LSP,
## MCP): see Shell-Direnv-Hook.md §"Directory Trust Gate".
##
## Record file `$XDG_CONFIG_HOME/repro/allow/<blake3(root)>`:
##   line 1: normalized absolute project root
##   line 2: `recipe=<blake3 hex of the closure>`
## A record without line 2 (written by an older `repro allow`) is stale and
## does not trust anything.
import std/[os, strutils, algorithm, sets]
import blake3
import ./cache_key

type DirectoryTrust* = enum
  dtTrusted        ## record exists and its closure digest matches
  dtUntrusted      ## no usable record for this root
  dtRecipeChanged  ## recorded, but the recipe closure differs now

const RecipeKey = "recipe="

proc hexDigest(data: string): string =
  blake3.digest(data).toHex()

proc allowRecordPath*(projectRoot: string): string =
  getConfigDir() / "repro" / "allow" / hexDigest(projectRoot)

proc joinStatements(source: string): string =
  ## Fold multi-line import statements onto one line, so a hostile module
  ## cannot hide behind `import\n  a,\n  b` or a trailing comma. Folds a line
  ## ending in `,` / `[` / bare `import|include|from` into its successor.
  var cur = ""
  var joining = false
  for raw in source.splitLines:
    let line = raw.strip()
    if joining:
      cur.add(" " & line)
    else:
      cur = line
    joining = cur.endsWith(",") or cur.endsWith("[") or
      cur in ["import", "include", "from"]
    if not joining:
      result.add(cur & "\n")
  if joining: result.add(cur & "\n")

proc localImportCandidates(source: string): seq[string] =
  ## Module paths named by `import`/`include`/`from ... import` statements,
  ## over-approximated: every name is later kept only if it resolves to a file
  ## under the project root, so extra names cost nothing.
  for rawLine in joinStatements(source).splitLines:
    let line = rawLine.strip()
    var rest = ""
    if line.startsWith("import ") or line.startsWith("include "):
      rest = line.split(' ', maxsplit = 1)[1]
    elif line.startsWith("from "):
      rest = line.split(' ', maxsplit = 1)[1].split(" import ")[0]
    else:
      continue
    let hash = rest.find('#')
    if hash >= 0: rest = rest[0 ..< hash]
    # `import a/[b, c]` and `import a, b as c`: flatten brackets and commas.
    var expanded: seq[string]
    let br = rest.find("/[")
    if br >= 0:
      let prefix = rest[0 ..< br]
      for part in rest[br + 2 .. ^1].split({',', ']'}):
        if part.strip().len > 0: expanded.add(prefix & "/" & part.strip())
    else:
      for part in rest.split(','):
        expanded.add(part.strip().split(" as ")[0].split(" except ")[0]
          .strip().strip(chars = {'"'}))
    for e in expanded:
      if e.len > 0: result.add(e)

proc resolveLocalModule(baseDir, projectRoot, name: string): string =
  for dir in [baseDir, projectRoot]:
    for cand in [dir / name, dir / (name & ".nim")]:
      if fileExists(cand) and cand.endsWith(".nim"):
        let norm = os.normalizedPath(absolutePath(cand))
        # Files outside the root are not part of what a checkout can change.
        if norm.startsWith(projectRoot & DirSep): return norm
  ""

proc quotedOrPathTokens(source: string): seq[string] =
  ## Every path-shaped token in the file. A superset of the import statements
  ## (also catches `staticRead`/`include` forms the line scanner misses);
  ## tokens that do not resolve to a local file are discarded by the caller.
  var tok = ""
  for ch in source & "\n":
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '/', '-'}:
      tok.add ch
    else:
      if tok.len > 1: result.add tok
      tok = ""

proc recipeClosureFiles*(projectRoot: string): seq[string] =
  ## Sorted absolute paths of the recipe's local source files.
  var seen = initHashSet[string]()
  var work: seq[string]
  let pf = canonicalProjectFilePath(projectRoot)
  if pf.len > 0: work.add(pf)
  while work.len > 0:
    let f = work.pop()
    if f in seen: continue
    seen.incl f
    var src = ""
    try: src = readFile(f)
    except CatchableError: continue
    for name in localImportCandidates(src) & quotedOrPathTokens(src):
      let m = resolveLocalModule(parentDir(f), projectRoot, name)
      if m.len > 0 and m notin seen: work.add(m)
  # Compiler configuration next to the recipe runs code at compile time too.
  for cfg in ["config.nims", "nim.cfg", "repro.nims", "reprobuild.nims"]:
    if fileExists(projectRoot / cfg): seen.incl(projectRoot / cfg)
  for f in seen: result.add(f)
  result.sort()

proc recipeClosureDigest*(projectRoot: string): string =
  ## Hex BLAKE3 over the closure's relative paths and contents. Contents are
  ## length-prefixed so file boundaries cannot be shifted.
  var buf = ""
  for f in recipeClosureFiles(projectRoot):
    let rel = relativePath(f, projectRoot)
    let body = try: readFile(f) except CatchableError: "<unreadable>"
    buf.add("file\n" & rel & "\n" & $body.len & "\n" & body & "\n")
  buf.add("lock\n" & lockSliceFilePart(projectRoot) & "\n")
  buf.add("overrides\n" &
    fileFingerprintPart(developOverridesMetadataPath(projectRoot)) & "\n")
  hexDigest(buf)

proc writeAllowRecord*(projectRoot: string) =
  let path = allowRecordPath(projectRoot)
  createDir(parentDir(path))
  writeFile(path, projectRoot & "\n" & RecipeKey &
    recipeClosureDigest(projectRoot) & "\n")

proc directoryTrustState*(projectRoot: string): DirectoryTrust =
  let path = allowRecordPath(projectRoot)
  if not fileExists(path): return dtUntrusted
  var lines: seq[string]
  try: lines = readFile(path).splitLines()
  except CatchableError: return dtUntrusted
  if lines.len < 2 or lines[0].strip() != projectRoot or
      not lines[1].startsWith(RecipeKey):
    return dtUntrusted
  if lines[1][RecipeKey.len .. ^1].strip() == recipeClosureDigest(projectRoot):
    dtTrusted
  else:
    dtRecipeChanged
