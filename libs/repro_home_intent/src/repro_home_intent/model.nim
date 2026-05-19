## Intermediate-representation types shared between the parser and the
## structural editor. The IR is a thin line-range map over the original
## source: each node records the byte range it occupies plus its
## indentation level so the editor can splice new lines in without
## disturbing surrounding formatting.

import std/options

import ./predicate

type
  NodeKind* = enum
    nkProfileRoot
    nkActivity
    nkCondBlock        ## `when <pred>:` or `if <pred>:`
    nkPackageRef       ## bare package-reference line
    nkConfigBlock      ## the `config:` block
    nkConfigPackage    ## `<pkg>:` sub-block inside `config:`
    nkConfigEntry      ## `<key> = <value>` line
    nkHostsBlock       ## the `hosts:` block
    nkHostsEntry       ## `<host>: [<acts>]` line

  CondKeyword* = enum
    ckWhen, ckIf

  IntentNode* = ref object
    ## Each node describes one structural item the parser recognized.
    ## `startLine` and `endLine` are 1-based, inclusive, and refer to
    ## the underlying lines array stored on the `Profile` (below).
    ## `indent` is the column (0-based) where the recognized content
    ## starts; nested children indent at `indent + indentStep`.
    startLine*, endLine*: int
    indent*: int
    case kind*: NodeKind
    of nkProfileRoot:
      name*: string                  ## e.g. "zahary" from `profile "zahary":`
      headerLine*: int               ## line of the `profile <name>:` line
      children*: seq[IntentNode]
    of nkActivity:
      activityName*: string
      activityHeaderLine*: int       ## line of `activity <name>:`
      activityChildren*: seq[IntentNode]
    of nkCondBlock:
      keyword*: CondKeyword
      predicateSource*: string       ## the raw text between the
                                     ## keyword and the trailing `:`
      predicateAst*: PredNode
      canonicalPredicate*: string    ## normalized canonical form
      condHeaderLine*: int
      condChildren*: seq[IntentNode]
    of nkPackageRef:
      packageName*: string
      packageLine*: int
    of nkConfigBlock:
      configHeaderLine*: int
      configPackages*: seq[IntentNode]
    of nkConfigPackage:
      configPackageName*: string
      configPackageHeaderLine*: int
      configEntries*: seq[IntentNode]
    of nkConfigEntry:
      configKey*: string
      configValueSource*: string     ## raw RHS bytes, no leading `=`
      configEntryLine*: int
    of nkHostsBlock:
      hostsHeaderLine*: int
      hostsEntries*: seq[IntentNode]
    of nkHostsEntry:
      hostName*: string
      hostActivities*: seq[string]
      hostEntryLine*: int

  Profile* = ref object
    ## Parsed and validated profile. `lines` is the source split on
    ## newlines (LF or CRLF — `parser.parseProfile` records the
    ## detected line ending). The editor mutates `lines` in place and
    ## then `editor.serialize` reassembles them with the original
    ## ending.
    path*: string
    lines*: seq[string]
    lineEnding*: string                ## "\n" or "\r\n"
    hasTrailingNewline*: bool
    root*: IntentNode                  ## the `profile <name>:` node
    indentStep*: int                   ## detected indent width (usually 2)

proc lineCount*(p: Profile): int = p.lines.len

proc findActivity*(p: Profile; name: string): Option[IntentNode] =
  for ch in p.root.children:
    if ch.kind == nkActivity and ch.activityName == name:
      return some(ch)
  none(IntentNode)

proc findConfigBlock*(p: Profile): Option[IntentNode] =
  for ch in p.root.children:
    if ch.kind == nkConfigBlock:
      return some(ch)
  none(IntentNode)

proc findHostsBlock*(p: Profile): Option[IntentNode] =
  for ch in p.root.children:
    if ch.kind == nkHostsBlock:
      return some(ch)
  none(IntentNode)
