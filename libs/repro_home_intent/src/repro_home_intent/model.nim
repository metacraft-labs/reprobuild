## Intermediate-representation types shared between the parser and the
## structural editor. The IR is a thin line-range map over the original
## source: each node records the byte range it occupies plus its
## indentation level so the editor can splice new lines in without
## disturbing surrounding formatting.

import std/[options, tables]

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
    nkResourcesBlock   ## the `resources:` block (M78)
    nkResourceEntry    ## `<kind> <address>:` resource declaration (M78)
    nkResourceAttr     ## `<key> = <value>` line inside a resource entry

  CondKeyword* = enum
    ckWhen, ckIf
    ckElif   ## an `elif <pred>:` branch of a `when` chain in `config:` /
             ## `resources:`; its `predicateAst` is the branch predicate
             ## conjoined with the negation of every earlier branch's
    ckElse   ## the `else:` branch of such a chain; its `predicateAst` is
             ## the conjunction of the negated earlier predicates

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
                                     ## (empty for `else:`)
      predicateAst*: PredNode        ## the guard the block applies: for
                                     ## `when` / `if` the parsed predicate,
                                     ## for `elif` / `else` the effective
                                     ## guard of that branch (see
                                     ## `CondKeyword`)
      canonicalPredicate*: string    ## normalized canonical form of
                                     ## `predicateAst`
      condHeaderLine*: int
      condChildren*: seq[IntentNode]
    of nkPackageRef:
      packageName*: string
      packageLine*: int
      packageVersion*: string        ## M69: the literal version pin from
                                     ## `package(<id>, "<version>")`, or
                                     ## "" for a bare-identifier reference
                                     ## (and for the bare `package(<id>)`
                                     ## call form). The structural editor
                                     ## round-trips this verbatim.
      packageBinaries*: seq[string]  ## 2026-06-09: explicit binary names
                                     ## the package installs, used by
                                     ## path-based catalog adapters when
                                     ## the package name doesn't match
                                     ## the binary name (e.g. nixpkgs
                                     ## `ripgrep` ships `rg`). Empty seq
                                     ## preserves pre-2026-06 behavior:
                                     ## the adapter probes `packageName`
                                     ## itself.
    of nkConfigBlock:
      configHeaderLine*: int
      configPackages*: seq[IntentNode]
        ## `nkConfigPackage` blocks, and -- for a `when <pred>:` chain
        ## around package blocks (GM3) -- `nkCondBlock`s whose
        ## `condChildren` are further package blocks / guarded blocks.
        ## Walk it with `applicableConfigPackages`, which evaluates the
        ## guards; never read the packages directly.
    of nkConfigPackage:
      configPackageName*: string
      configPackageHeaderLine*: int
      configEntries*: seq[IntentNode]
        ## `nkConfigEntry` lines, and `nkCondBlock`s whose
        ## `condChildren` are the `nkConfigEntry`s (or nested guarded
        ## blocks) a runtime guard selects (GM3: a `when <pred>:` chain
        ## inside the package block, parsed from source or adapted from a
        ## compiled `ProfileIntent`). Walk it with
        ## `applicableConfigEntries`, which evaluates the guards; never
        ## read the entries directly.
    of nkConfigEntry:
      configKey*: string
      configValueSource*: string     ## raw RHS bytes, no leading `=`
      configEntryLine*: int
      configIntentOrdinal*: int
        ## 1-based position of the `ConfigOverride` this entry was
        ## adapted from in the compiled `ProfileIntent.configOverrides`;
        ## 0 for an entry parsed from source text. Lets a consumer of the
        ## planner's selection (`repro home export --target`) name the
        ## intent element the planner chose.
    of nkHostsBlock:
      hostsHeaderLine*: int
      hostsEntries*: seq[IntentNode]
    of nkHostsEntry:
      hostName*: string
      hostActivities*: seq[string]
      hostEntryLine*: int
    of nkResourcesBlock:
      ## The single `resources:` block. Direct children are
      ## `nkResourceEntry` declarations and `nkCondBlock` predicate
      ## blocks that nest further `nkResourceEntry` declarations
      ## (a `when windows:`-guarded resource).
      resourcesHeaderLine*: int
      resourcesEntries*: seq[IntentNode]
    of nkResourceEntry:
      ## One `<kind> <address>:` resource declaration. `resourceKind`
      ## is the typed home-scope kind tag (`env.userPath`,
      ## `fs.managedBlock`, `shell.integration`, `env.userVariable`,
      ## `windows.registryValue`, `windows.startup`); `resourceAddress`
      ## is the stable id used downstream as the `Resource.address`.
      resourceKind*: string
      resourceAddress*: string
      resourceHeaderLine*: int
      resourceAttrs*: seq[IntentNode]
      resourceIntentOrdinal*: int
        ## 1-based position of the `ResourceIntent` this entry was
        ## adapted from in the compiled `ProfileIntent.resources`; 0 for
        ## an entry parsed from source text (see `configIntentOrdinal`).
    of nkResourceAttr:
      ## A `<key> = <value>` payload line inside a resource entry.
      resourceAttrKey*: string
      resourceAttrValueSource*: string  ## raw RHS bytes, no leading `=`
      resourceAttrLine*: int

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
    adapterPreference*: OrderedTable[string, seq[string]]
      ## The profile's selection policy (GM4b), parsed from a top-level
      ## `adapterPreference:` block inside the `profile` body. Keys are
      ## canonical OS tags (`"windows"`, `"linux"`, `"darwin"`); values
      ## are the ordered realization kinds (each drawn from the closed
      ## set `{"tarball", "builtin", "scoop", "nix", "path"}`; `builtin`
      ## is the former spelling of `tarball`). Empty table when the block
      ## is absent — resolution then uses the default selection policy,
      ## the same on every platform. A partial table (e.g. only
      ## `"windows"` set) uses the default for each missing OS at resolve
      ## time. `darwin` and `macos` are
      ## aliased at parse time to the canonical `"darwin"` key so a
      ## single lookup at resolve time suffices.
    dataFileRefs*: seq[string]
      ## GM4: the plan-time data files the profile's `data:` section
      ## names, relative to the profile directory. Parsed from source by
      ## the text inspector (`repro home add --data` refuses a file not
      ## listed here); empty for a profile adapted from a compiled intent,
      ## whose rows are already expanded (see `loadedDataFiles`).
    loadedDataFiles*: seq[LoadedDataFile]
      ## GM4: the data files the planner read for this profile, with the
      ## exact bytes it expanded. Set by the compile-then-adapt path; the
      ## apply pipeline records them in the generation's intent snapshot so
      ## the generation keeps the data it was planned from (rollback and
      ## `repro home history` never re-read the live file).

  LoadedDataFile* = object
    ## One plan-time data file as read: its reference and its bytes.
    path*: string
    content*: string

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

proc findResourcesBlock*(p: Profile): Option[IntentNode] =
  ## Locate the unique `resources:` block (M78), if present.
  for ch in p.root.children:
    if ch.kind == nkResourcesBlock:
      return some(ch)
  none(IntentNode)
