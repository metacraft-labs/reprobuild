## The members of a bundle's tar stream, as GNU tar itself reads them, and
## the rules a bundle import applies to them before it writes anything.
##
## A bundle's part hashes come from the same unsigned manifest as the parts,
## so whoever serves a bundle can serve any stream. Extraction is confined
## only by what the importer checks first: it lists the archive with the same
## GNU tar that will extract it, over the same verified parts, and refuses
## unless every member is one it expects (docs/store-bundles.md §5,
## docs/workspace-bundles.md §7). Reading tar's own interpretation of the
## stream, rather than parsing tar headers here, means the check sees exactly
## the names, types and link targets extraction will act on: pax overrides,
## GNU long names and every other header extension included.
##
## The listing is the output of
##
##   LC_ALL=C tar -tvf - --quoting-style=c --numeric-owner --full-time
##
## one line per member:
##
##   -rw-r--r-- 1000/100          3 2026-11-16 02:15:44.315325752 "a/b/f"
##   hrw-r--r-- 1000/100          0 2026-11-16 02:15:44.315325752 "a/b/hl" link to "a/b/f"
##   lrwxrwxrwx 1000/100          0 2026-11-16 02:15:44.325325783 "a/sym" -> "../x"
##   drwxr-xr-x 1000/100          0 2026-11-16 02:15:44.33432581 "a/"
##
## The first character is the member type (GNU tar's `list.c`,
## `print_header`: `-` file, `h` hard link, `l` symlink, `d` directory, and
## other letters for fifos, devices and GNU extensions). With
## `--numeric-owner` nothing before the name contains `"`, so the name is the
## first C-quoted string on the line; `--quoting-style=c` escapes `"`, `\`
## and every non-printable byte, so each member is exactly one line, and
## under `LC_ALL=C` every non-ASCII byte is a `\ooo` octal escape. See
## https://www.gnu.org/software/tar/manual/html_node/quoting-styles.html.
## Names are listed as stored: a leading `/` is shown even though extraction
## would strip it, which is why such a name is refused rather than trusted.

import std/[sets, strutils, tables]

type
  TarMember* = object
    ## One line of the listing.
    kind*: char          ## the type letter: '-', 'h', 'l', 'd', or another
    name*: string        ## the member name, C escapes decoded
    linkTarget*: string  ## a hard link's or a symlink's target, else ""

  MemberSet* = object
    ## The members admitted so far, by canonical name, with their type.
    kinds: Table[string, char]
    symlinks: int

  DeclaredKind* = enum
    dkPlainFile  ## a regular file carried as itself, never as a hard link
    dkFile       ## a regular file, which tar may carry as a hard link
    dkDir
    dkLink

  DeclaredMember* = object
    ## What a bundle's own description says a member is.
    kind*: DeclaredKind
    target*: string      ## the link target of a `dkLink`

const
  CarriedKinds* = {'-', 'h', 'l', 'd'}
    ## Regular file, hard link, symlink, directory: everything a bundle
    ## carries. Fifos, devices, contiguous files, volume headers and the
    ## other GNU types never occur in one, and some (a device node) would be
    ## dangerous to create.
  HardLinkInfix = " link to "
  SymlinkInfix = " -> "
  NixStoreDir* = "/nix/store"
  NixStoreNameChars* = {'A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.', '_',
    '?', '='}
    ## The characters Nix allows in a store path name (Nix's
    ## `checkPathName`, src/libstore/path.cc).

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc unquoteC*(text: string; start: int; stop: var int): string =
  ## The C-quoted string that opens at `text[start]` (a `"`), decoded; `stop`
  ## is set to the index just past its closing quote. Decodes the escapes
  ## GNU tar's `c` quoting style writes: `\\ \" \n \t \a \b \f \r \v \?` and
  ## `\ooo`. Raises ValueError on anything else, an unterminated string, or
  ## an escape that decodes to NUL or beyond one byte.
  if start >= text.len or text[start] != '"':
    raise newException(ValueError, "expected a quoted name")
  var i = start + 1
  while i < text.len:
    let ch = text[i]
    if ch == '"':
      stop = i + 1
      return
    if ch != '\\':
      result.add(ch)
      inc i
      continue
    if i + 1 >= text.len:
      break
    let e = text[i + 1]
    case e
    of '\\': result.add('\\')
    of '"': result.add('"')
    of 'n': result.add('\n')
    of 't': result.add('\t')
    of 'a': result.add('\a')
    of 'b': result.add('\b')
    of 'f': result.add('\f')
    of 'r': result.add('\r')
    of 'v': result.add('\v')
    of '?': result.add('?')
    of '0'..'7':
      if i + 3 >= text.len or text[i + 2] notin {'0'..'7'} or
          text[i + 3] notin {'0'..'7'}:
        raise newException(ValueError, "malformed octal escape")
      let value = (ord(e) - ord('0')) * 64 + (ord(text[i + 2]) - ord('0')) * 8 +
        (ord(text[i + 3]) - ord('0'))
      if value == 0 or value > 255:
        raise newException(ValueError, "octal escape outside one byte")
      result.add(char(value))
      i += 4
      continue
    else:
      raise newException(ValueError, "unknown escape \\" & e)
    i += 2
  raise newException(ValueError, "unterminated quoted name")

proc parseListingLine*(line: string): TarMember =
  ## One line of the verbose listing. Raises ValueError when the line is not
  ## one: a name that is not one well-formed quoted string, a hard link
  ## without ` link to "<target>"`, a symlink without ` -> "<target>"`, or
  ## anything after them.
  if line.len == 0:
    raise newException(ValueError, "empty listing line")
  result.kind = line[0]
  let open = line.find('"')
  if open < 0:
    raise newException(ValueError, "no quoted name in listing line")
  var stop = 0
  result.name = unquoteC(line, open, stop)
  let infix =
    case result.kind
    of 'h': HardLinkInfix
    of 'l': SymlinkInfix
    else: ""
  if infix.len > 0:
    if not line.continuesWith(infix, stop):
      raise newException(ValueError, "link member without its target")
    result.linkTarget = unquoteC(line, stop + infix.len, stop)
  if stop != line.len:
    raise newException(ValueError, "unexpected text after the member name")

iterator listingMembers*(path: string): tuple[line: int; member: TarMember] =
  ## The members of a listing file, read a line at a time (a Nix half lists
  ## about a million). Raises ValueError naming the line it cannot read.
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot read the archive listing " & path)
  defer: f.close()
  var lineNo = 0
  var line: string
  while f.readLine(line):
    inc lineNo
    var m: TarMember
    try:
      m = parseListingLine(line)
    except ValueError as e:
      raise newException(ValueError, "archive listing line " & $lineNo &
        " is not a member (" & e.msg & "): " & line.escape)
    yield (lineNo, m)

proc memberPath*(m: TarMember): string =
  ## The member's name without the one trailing `/` a directory carries.
  result = m.name
  if m.kind == 'd' and result.len > 1 and result.endsWith('/'):
    result.setLen(result.len - 1)

proc relativeNameProblem*(name: string): string =
  ## "" when `name` is canonical and relative: not empty, no leading `/`, and
  ## no empty, `.` or `..` component. Tar strips a leading `/` and refuses
  ## some `..` names on its own, but only a name in this form is written
  ## where it reads.
  if name.len == 0:
    return "an empty name"
  if name[0] == '/':
    return "an absolute name"
  for component in name.split('/'):
    if component.len == 0 or component == "." or component == "..":
      return "a name that is not canonical (empty, `.` or `..` component)"
  ""

# ---------------------------------------------------------------------------
# The rules every half applies
# ---------------------------------------------------------------------------

proc quoted(name: string): string =
  ## A name as a message shows it: one line, whatever bytes it holds.
  name.escape

proc initMemberSet*(): MemberSet =
  MemberSet(kinds: initTable[string, char]())

proc len*(s: MemberSet): int = s.kinds.len

proc contains*(s: MemberSet; name: string): bool = name in s.kinds

proc kindOf*(s: MemberSet; name: string): char =
  ## The type letter of the admitted member `name`, or '\0'.
  s.kinds.getOrDefault(name, '\0')

proc admit*(s: var MemberSet; m: TarMember): string =
  ## Check `m` against the rules every bundle half applies, and record it.
  ## "" when it is acceptable, otherwise the reason, naming the member:
  ## * its type is a file, a hard link, a symlink or a directory;
  ## * its name is canonical and relative;
  ## * no other member has that name;
  ## * a hard link's target obeys the same rules and is an earlier
  ##   regular-file member (GNU tar always archives a file before the links
  ##   to it; a link to a name not yet extracted would link whatever is
  ##   already on disk there).
  ## The symlink-ancestor rule needs every name, so it is in `finish`.
  if m.kind notin CarriedKinds:
    return "member " & quoted(m.name) & " has type '" & m.kind &
      "', which a bundle never carries"
  let name = m.memberPath
  let problem = relativeNameProblem(name)
  if problem.len > 0:
    return "member " & quoted(m.name) & " has " & problem
  if name in s.kinds:
    return "member " & quoted(m.name) & " occurs more than once"
  if m.kind == 'h':
    let targetProblem = relativeNameProblem(m.linkTarget)
    if targetProblem.len > 0:
      return "hard link " & quoted(m.name) & " names " &
        quoted(m.linkTarget) & ", " & targetProblem
    if s.kinds.getOrDefault(m.linkTarget, '\0') != '-':
      return "hard link " & quoted(m.name) & " names " &
        quoted(m.linkTarget) & ", which is not an earlier regular-file member"
  s.kinds[name] = m.kind
  if m.kind == 'l':
    inc s.symlinks

proc finish*(s: MemberSet): string =
  ## The rule that needs the whole set: no member lies below a symlink
  ## member, in whichever order the two occur. A link planted at `a` and a
  ## member `a/b` after it would write `b` wherever the link points; one
  ## before it is just as wrong, and the bundle's own description never
  ## declares either. "" when no member does.
  if s.symlinks == 0:
    return ""
  for name in s.kinds.keys:
    var slash = name.find('/')
    while slash > 0:
      let ancestor = name[0 ..< slash]
      if s.kinds.getOrDefault(ancestor, '\0') == 'l':
        return "member " & quoted(name) & " lies below the symlink member " &
          quoted(ancestor)
      slash = name.find('/', slash + 1)
  ""

# ---------------------------------------------------------------------------
# The native half: members are exactly what `contents` declares
# ---------------------------------------------------------------------------

proc declaredMemberProblem*(m: TarMember; d: DeclaredMember): string =
  ## "" when `m` is carried as the type `d` declares, with `d`'s link target.
  let ok =
    case d.kind
    of dkPlainFile: m.kind == '-'
    of dkFile: m.kind in {'-', 'h'}
    of dkDir: m.kind == 'd'
    of dkLink: m.kind == 'l'
  if not ok:
    return "member " & quoted(m.name) & " has type '" & m.kind &
      "', but the bundle declares " &
      (case d.kind
       of dkPlainFile, dkFile: "a file"
       of dkDir: "a directory"
       of dkLink: "a symlink")
  if d.kind == dkLink and m.linkTarget != d.target:
    return "symlink member " & quoted(m.name) & " points to " &
      quoted(m.linkTarget) & ", but the bundle declares " & quoted(d.target)
  ""

# ---------------------------------------------------------------------------
# The Nix half: members lie inside the registered store paths
# ---------------------------------------------------------------------------

proc nixStorePathProblem*(path: string): string =
  ## "" when `path` is `/nix/store/<name>` with `<name>` one component of
  ## store-name characters that does not start with `.`: the only form a
  ## registered path may take, so that it names a single directory entry of
  ## the store and nothing else.
  if not path.startsWith(NixStoreDir & "/"):
    return "registered path " & quoted(path) & " is not in " & NixStoreDir
  let name = path[NixStoreDir.len + 1 .. ^1]
  if name.len == 0 or name[0] == '.':
    return "registered path " & quoted(path) & " has no valid store name"
  for ch in name:
    if ch notin NixStoreNameChars:
      return "registered path " & quoted(path) &
        " is not a single store-path name"
  ""

proc nixMemberProblem*(name: string; registered: HashSet[string]): string =
  ## "" when `name` is `nix/store/<p>` or below it, for a registered
  ## `nix/store/<p>` (relative, as the half's tar stream names it). The store
  ## and `nix/` themselves are not members of a half.
  const prefix = "nix/store/"
  if name.startsWith(prefix):
    let slash = name.find('/', prefix.len)
    let path = (if slash < 0: name else: name[0 ..< slash])
    if path in registered:
      return ""
  "member " & quoted(name) & " lies outside the store paths the half registers"
