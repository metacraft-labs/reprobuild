## How a managed system file (`fs.systemFile`) is held: its permission
## bits (`mode`), its owning group (`group`) and, on a ReproOS add-on host,
## whether it is a link into the generation's static tree or a regular
## file (`form`).
##
## Every layer that accepts an `fs.systemFile` checks these three fields
## with the procs below: the profile constructor (`repro_profile`), the
## intent adapter (`repro_profile_compile`), the text parser
## (`repro_infra.parseSystemProfile`) and the privileged operation's
## closed-set validator (`repro_elevation.operationValidationError`). One
## definition, so the four layers cannot disagree about what is refused.
##
## The rules (reprobuild-pm `spec/System-Profile-And-Infra-Apply.md`,
## `fs.systemFile`, amended 2026-11-16; ReproOS-Add-On-Mode §7.2 step 5):
##
## * `mode` is four octal digits, `0000`-`0777`: the exact permission bits
##   the file has after every apply. The setuid, setgid and sticky bits are
##   refused (a root-owned managed file is never a setuid program), and so
##   is the bit that lets every user write it (`0002`). Empty: undeclared,
##   the earlier rule holds (the replaced regular file's bits, else 0644).
## * `group` is a group name; the file is owned by `root:<group>`. Empty:
##   `root:root`.
## * `form` is `link`, `copy` or empty. Only an add-on host reads it. A
##   file that declares `mode` or `group` is a copy, and `form = "link"`
##   with either is refused: a link has no mode or group of its own, and
##   its bytes would sit in the world-readable static tree.
##
## Pure: no I/O. The group is resolved to a gid by the driver, at write
## time (`getgrnam(3)`).

import std/strutils

const
  SystemFileForms* = ["link", "copy"]
    ## The values `form` may take besides "" (undeclared).
  MaxGroupNameLen* = 64
    ## Longer than any group name the shadow tools create (`groupadd`
    ## refuses more than 32 characters by default); a bound so a hostile
    ## profile cannot hand the driver an arbitrarily long lookup key.

proc systemFileModeError*(mode: string): string =
  ## "" when `mode` is empty (undeclared) or a permitted declaration;
  ## otherwise why it is refused.
  if mode.len == 0:
    return ""
  if mode.len != 4:
    return "mode '" & mode & "' is not four octal digits (write it as " &
      "`0640`, not `640`)"
  for c in mode:
    if c notin {'0' .. '7'}:
      return "mode '" & mode & "' is not four octal digits"
  if mode[0] != '0':
    return "mode '" & mode & "' sets the setuid, setgid or sticky bit; a " &
      "managed system file is owned by root and never carries them"
  if (parseOctInt(mode) and 0o002) != 0:
    return "mode '" & mode & "' lets every user write the file; a " &
      "managed system file is never writable by others"
  ""

proc systemFileGroupError*(group: string): string =
  ## "" when `group` is empty (undeclared) or a well-formed group name;
  ## otherwise why it is refused. A name is letters, digits, `_`, `.` and
  ## `-`, does not start with `-`, and is not all digits (a numeric name
  ## reads as a gid to `chgrp(1)` and to a reader of the ledger).
  if group.len == 0:
    return ""
  if group.len > MaxGroupNameLen:
    return "group name is longer than " & $MaxGroupNameLen & " characters"
  if group[0] == '-':
    return "group '" & group & "' starts with '-'"
  var allDigits = true
  for c in group:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '.', '-'}:
      return "group '" & group.escape() & "' contains a character outside " &
        "letters, digits, '_', '.' and '-'"
    if c notin {'0' .. '9'}:
      allDigits = false
  if allDigits:
    return "group '" & group & "' is all digits; name the group, not its gid"
  ""

proc systemFileFormError*(form, mode, group: string): string =
  ## "" when `form` is undeclared or permitted together with `mode` and
  ## `group`; otherwise why it is refused.
  if form.len == 0 or form == "copy":
    return ""
  if form != "link":
    return "form '" & form & "' is not one of " & SystemFileForms.join(" / ")
  if mode.len > 0 or group.len > 0:
    return "form 'link' cannot be combined with `mode` or `group`: a link " &
      "has no mode or group of its own, and its bytes would be readable " &
      "by every user through the static tree; drop `form` or write " &
      "`form = \"copy\"`"
  ""

proc systemFileHoldingError*(mode, group, form: string): string =
  ## The first refusal among `mode`, `group` and `form`, or "".
  result = systemFileModeError(mode)
  if result.len == 0: result = systemFileGroupError(group)
  if result.len == 0: result = systemFileFormError(form, mode, group)

proc systemFileIsCopy*(mode, group, form: string): bool =
  ## Whether an add-on host materialises the file as a regular file
  ## rather than a link into the static tree: when it says so, or when it
  ## declares a mode or a group (which a link cannot carry).
  form == "copy" or mode.len > 0 or group.len > 0

proc systemFileDeclaresAttributes*(mode, group: string): bool =
  ## Whether the file's observed state covers its mode and group as well
  ## as its content (see `systemFileStateText`).
  mode.len > 0 or group.len > 0

proc systemFileStateText*(contentDigestHex, mode, group: string): string =
  ## The canonical text whose digest is the state of a file that declares
  ## `mode` or `group`: the content digest and each declared attribute.
  ## The desired side passes the declaration; the observer passes what it
  ## saw for the fields the resource declares, so both sides render the
  ## same text exactly when the file is as declared. A file that declares
  ## neither is not described by this text: its state is its content
  ## digest alone, as before the fields existed.
  result = "fs.systemFile.state.v1\ncontent=" & contentDigestHex & "\n"
  if mode.len > 0:
    result.add("mode=" & mode & "\n")
  if group.len > 0:
    result.add("group=" & group & "\n")

proc systemFileLinkedCopyStateText*(contentDigestHex: string): string =
  ## The canonical text whose digest is the observed state of a file that
  ## is a copy (`systemFileIsCopy`) but is found as a link resolving to
  ## `contentDigestHex`. No desired state renders `form=link`, so the
  ## digest never equals one: the link is drift, and the apply replaces it
  ## with a copy, even when the bytes it resolves to are the declared ones
  ## (an add-on switch plans before it flips the static tree, and the new
  ## tree does not carry a copy's bytes).
  "fs.systemFile.state.v1\ncontent=" & contentDigestHex & "\nform=link\n"
