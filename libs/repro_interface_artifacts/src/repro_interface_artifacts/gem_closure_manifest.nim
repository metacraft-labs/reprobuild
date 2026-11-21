## The gem-closure manifest grammar: a pinned, already-resolved set of Ruby
## gems that a tarball arm's ``gemClosure`` step installs, offline, into the
## realized Ruby prefix.
##
## One gem per non-comment line, whitespace-delimited and unquoted:
##
##   <name> <version> <platform> <sha256> <url>
##
## - ``name``: ``[A-Za-z0-9_.-]+``, at most one line per name;
## - ``version``: a RubyGems version string (digits and letters separated by
##   dots, as ``Gem::Version`` accepts them);
## - ``platform``: ``ruby`` for a source gem, or a RubyGems platform
##   (``x64-mingw-ucrt``) for a prebuilt one, which the declaring record must
##   list in its substitutions;
## - ``sha256``: 64 lowercase hex digits;
## - ``url``: ``https://``, whose last path component is the gem's file name
##   (``<name>-<version>.gem``, or ``<name>-<version>-<platform>.gem``).
##
## ``#`` lines and blank lines are ignored. **Line order is install order**:
## the installer resolves nothing (``--ignore-dependencies``), so a gem whose
## build needs another gem is installed after it, and the generator writes
## dependencies first.
##
## The manifest is GENERATED from the Ruby-with-gems closure the Nix side
## already pins (nixpkgs fetches each gem from
## ``https://rubygems.org/gems/<name>-<version>.gem``, so its hash is the
## same bytes), and is read by a reviewer as a lock file: a flat text format
## with one gem per line keeps "one gem moved" a one-line diff.
##
## This module is the one place the grammar is parsed: by the lift that
## inlines a manifest into a published record, and by the realization that
## installs it. Every refusal names the file and the offending line, and the
## WHOLE manifest is validated before any gem is fetched.

import std/[algorithm, sequtils, strutils]

type
  GemClosureEntry* = object
    ## One gem the manifest names.
    name*: string
    version*: string
    platform*: string
      ## ``ruby`` for a source gem.
    sha256*: string
    url*: string

  GemBuildArgs* = object
    ## The extconf arguments one gem is built with (``gem install ... --
    ## <args>``). ``$REPRO_PREFIX_<NAME>`` in an argument names the realized
    ## prefix of the step tool ``<name>`` (upper-cased, ``-`` read as ``_``).
    gem*: string
    args*: seq[string]

const
  GemSourcePlatform* = "ruby"
    ## The platform of a source gem, whose native extensions are compiled
    ## at install.
  GemNeverSubstituted* = ["nokogiri"]
    ## Gems whose prebuilt platform gem may never be admitted: nokogiri is
    ## always compiled from source against the provisioned libxml2 and
    ## libxslt, never taken with the libraries its platform gem bundles.
  GemPrefixReferenceStart* = "$REPRO_PREFIX_"

proc isGemNameChar(c: char): bool =
  c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '.', '-'}

proc validGemName*(name: string): bool =
  name.len > 0 and name.allIt(isGemNameChar(it))

proc validGemVersion*(version: string): bool =
  ## ``Gem::Version``'s pattern: alphanumeric segments separated by single
  ## dots (``1.18.10``, ``2.0.0.rc1``), starting with a digit. No ``-``,
  ## because a ``-`` would make the file name ambiguous with the platform.
  if version.len == 0 or version[0] notin {'0' .. '9'}:
    return false
  for segment in version.split('.'):
    if segment.len == 0 or
        not segment.allIt(it in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z'}):
      return false
  true

proc validGemPlatform*(platform: string): bool =
  ## ``ruby``, or a RubyGems platform string such as ``x64-mingw-ucrt``,
  ## ``x86_64-linux`` or ``arm64-darwin``.
  platform.len > 0 and
    platform.allIt(it in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-', '.'})

proc gemFileName*(entry: GemClosureEntry): string =
  ## The file name RubyGems publishes the gem under, and the name the
  ## manifest's URL must end in.
  if entry.platform == GemSourcePlatform:
    entry.name & "-" & entry.version & ".gem"
  else:
    entry.name & "-" & entry.version & "-" & entry.platform & ".gem"

proc refuse(origin, line, reason: string) {.noreturn.} =
  raise newException(ValueError, "tool-resolution failed: gem closure " &
    "manifest " & origin & ": " & reason & ": " & line)

proc parseGemClosureManifestText*(text, origin: string):
    seq[GemClosureEntry] =
  ## Parse and validate the whole manifest. ``origin`` names the file (or the
  ## record whose inlined entries these are) in every refusal.
  var names: seq[string]
  var lineNumber = 0
  for rawLine in text.splitLines():
    inc lineNumber
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let at = origin & ":" & $lineNumber
    let parts = line.splitWhitespace()
    if parts.len != 5:
      refuse(at, line, "a line is \"<name> <version> <platform> <sha256> " &
        "<url>\" (" & $parts.len & " fields)")
    var entry = GemClosureEntry(name: parts[0], version: parts[1],
      platform: parts[2], sha256: parts[3], url: parts[4])
    if not validGemName(entry.name):
      refuse(at, line, "the name must match [A-Za-z0-9_.-]+")
    if entry.name in names:
      refuse(at, line, "gem " & entry.name & " is named twice (one line " &
        "per gem)")
    if not validGemVersion(entry.version):
      refuse(at, line, "the version is not a RubyGems version string")
    if not validGemPlatform(entry.platform):
      refuse(at, line, "the platform must be \"ruby\" or a RubyGems " &
        "platform such as x64-mingw-ucrt")
    if entry.sha256.len != 64 or
        not entry.sha256.allIt(it in {'0' .. '9', 'a' .. 'f'}):
      refuse(at, line, "the sha256 must be 64 lowercase hex digits")
    if not entry.url.startsWith("https://"):
      refuse(at, line, "the url must be https://")
    let path = entry.url["https://".len .. ^1].split({'?', '#'})[0]
    let slash = path.rfind('/')
    if slash < 0 or path[slash + 1 .. ^1] != gemFileName(entry):
      refuse(at, line, "the url must end in " & gemFileName(entry))
    names.add(entry.name)
    result.add(entry)

proc canonicalGemLine*(entry: GemClosureEntry): string =
  entry.name & " " & entry.version & " " & entry.platform & " " &
    entry.sha256 & " " & entry.url

proc gemClosureContentDigestInput*(entries: openArray[GemClosureEntry]):
    string =
  ## The text the manifest's identity is the digest of: the canonical lines,
  ## SORTED, as a closure manifest's identity is formed. A comment, a blank
  ## line or a reformat does not move it.
  var lines = entries.mapIt(canonicalGemLine(it))
  lines.sort()
  lines.join("\n")

proc gemPrefixReferences*(arg: string): seq[string] =
  ## The ``<NAME>`` of every ``$REPRO_PREFIX_<NAME>`` in ``arg``, in order.
  var i = 0
  while true:
    let at = arg.find(GemPrefixReferenceStart, i)
    if at < 0:
      break
    var j = at + GemPrefixReferenceStart.len
    while j < arg.len and arg[j] in {'A' .. 'Z', '0' .. '9', '_'}:
      inc j
    result.add(arg[at + GemPrefixReferenceStart.len ..< j])
    i = j

proc gemPrefixVariableName*(selector: string): string =
  ## ``libxml2-dev`` -> ``LIBXML2_DEV``: the ``<NAME>`` a build argument
  ## spells for the step tool ``selector``.
  for c in selector:
    result.add(if c in {'a' .. 'z'}: char(ord(c) - 32)
               elif c in {'A' .. 'Z', '0' .. '9'}: c
               else: '_')

proc validateGemClosureDeclaration*(entries: openArray[GemClosureEntry];
                                    substitutions: openArray[string];
                                    buildArgs: openArray[GemBuildArgs];
                                    stepToolSelectors: openArray[string];
                                    origin: string) =
  ## The checks that need the declaring record as well as the manifest:
  ##
  ## - a gem with a non-``ruby`` platform is admitted only when the record
  ##   lists its name in its substitutions, and nokogiri never is;
  ## - a substitution names a gem the manifest has, and never nokogiri;
  ## - every ``gemBuildArgs`` entry names a gem of the manifest, once;
  ## - every ``$REPRO_PREFIX_<NAME>`` names one of the step's tools.
  var manifestNames: seq[string]
  for entry in entries:
    manifestNames.add(entry.name)
  for name in substitutions:
    if name in GemNeverSubstituted:
      raise newException(ValueError, "tool-resolution failed: " & origin &
        " lists " & name & " as a prebuilt-gem substitution; " & name &
        " is always built from its source gem")
    if name notin manifestNames:
      raise newException(ValueError, "tool-resolution failed: " & origin &
        " lists " & name & " as a prebuilt-gem substitution, but the gem " &
        "manifest has no such gem")
  for entry in entries:
    if entry.platform != GemSourcePlatform and
        entry.name notin substitutions:
      raise newException(ValueError, "tool-resolution failed: " & origin &
        ": gem " & entry.name & " " & entry.version & " is the prebuilt " &
        entry.platform & " gem, which the declaration does not admit; " &
        "every gem is installed from its source (\"ruby\") gem unless the " &
        "record lists it in its prebuilt-gem substitutions")
  var argGems: seq[string]
  var known: seq[string]
  for selector in stepToolSelectors:
    known.add(gemPrefixVariableName(selector))
  for item in buildArgs:
    if item.gem notin manifestNames:
      raise newException(ValueError, "tool-resolution failed: " & origin &
        " gives build arguments for " & item.gem & ", which the gem " &
        "manifest does not name")
    if item.gem in argGems:
      raise newException(ValueError, "tool-resolution failed: " & origin &
        " gives build arguments for " & item.gem & " twice")
    argGems.add(item.gem)
    for arg in item.args:
      for name in gemPrefixReferences(arg):
        if name notin known:
          raise newException(ValueError, "tool-resolution failed: " &
            origin & ": the build argument \"" & arg & "\" of " & item.gem &
            " names $REPRO_PREFIX_" & name & ", which is not the prefix " &
            "of one of the step's build tools (" &
            (if known.len > 0: known.join(", ") else: "none") & ")")

proc canonicalGemBuildArgs*(buildArgs: openArray[GemBuildArgs]): seq[string] =
  ## One line per gem, sorted by gem name, each argument kept in order and
  ## separated by NUL-free tabs: the step's build configuration as it enters
  ## the prefix's identity.
  var items = @buildArgs
  items.sort(proc(a, b: GemBuildArgs): int = cmp(a.gem, b.gem))
  for item in items:
    result.add(item.gem & "\t" & item.args.join("\t"))
