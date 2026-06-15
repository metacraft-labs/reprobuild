## D2 P1: parse the dnf harvester's ``--source`` flag mini-grammar.
##
## Accepted forms:
##
##   dnf:htop@fedora/39:20260601
##   dnf:{htop,neovim}@fedora/39:20260601
##
## The brace-expansion form is the multi-package mode (mirrors
## ``apt:{...}``): the harvester walks the union closure of the listed
## packages and emits one catalog file per transitive dep with no
## duplicates.
##
## ## Snapshot grammar
##
## Fedora's snapshot pins use a ``YYYYMMDD`` date (or full timestamp).
## We accept any non-empty token: the harvester treats it as opaque
## and feeds it to the URL template.
##
## ## Default upstream
##
## When the harvest runs against a fixture (``--cache-dir`` + ``--offline``)
## the URL is only used as a cache key. Live harvests fall back to one of:
##
##   * Fedora compose (`kojipkgs.fedoraproject.org/compose/<distro>/<snapshot>`)
##   * Fedora Vault (`dl.fedoraproject.org/pub/archive/fedora/linux/<release>`)
##
## The default is configurable via ``--upstream`` (see harvester CLI).

import std/[strutils]

type
  DnfSourceSpec* = object
    distro*: string          ## "fedora" (canonical); "rhel" / "centos"
                             ## extend later.
    release*: string         ## "39", "40", "41" (Fedora release number)
    snapshot*: string        ## "20260601" or "20260601T000000Z"
    packages*: seq[string]

  SourceSpecError* = object of CatchableError

const KnownDnfDistros* = ["fedora"]

proc parseDnfSourceSpec*(raw: string): DnfSourceSpec =
  ## Parses ``dnf:<pkgs>@<distro>/<release>:<snapshot>``. Raises
  ## ``SourceSpecError`` on malformed input.
  if not raw.startsWith("dnf:"):
    raise newException(SourceSpecError,
      "dnf source spec must start with 'dnf:'; got: " & raw)
  let rest = raw[4 .. ^1]
  let atIdx = rest.find('@')
  if atIdx < 0:
    raise newException(SourceSpecError,
      "dnf source spec missing '@<distro>/<release>:<snapshot>' after " &
      "the package list: " & raw)
  let pkgPart = rest[0 ..< atIdx]
  let tail = rest[atIdx + 1 .. ^1]
  let slashIdx = tail.find('/')
  if slashIdx < 0:
    raise newException(SourceSpecError,
      "dnf source spec missing '/' between distro + release: " & raw)
  let distro = tail[0 ..< slashIdx]
  let suiteAndSnap = tail[slashIdx + 1 .. ^1]
  let colonIdx = suiteAndSnap.find(':')
  if colonIdx < 0:
    raise newException(SourceSpecError,
      "dnf source spec missing ':' between release + snapshot: " & raw)
  let release = suiteAndSnap[0 ..< colonIdx]
  let snapshot = suiteAndSnap[colonIdx + 1 .. ^1]

  result.distro = distro
  result.release = release
  result.snapshot = snapshot

  if pkgPart.len == 0:
    raise newException(SourceSpecError,
      "dnf source spec has empty package list: " & raw)
  if pkgPart[0] == '{':
    if not pkgPart.endsWith("}"):
      raise newException(SourceSpecError,
        "dnf source spec brace group not closed: " & raw)
    let inner = pkgPart[1 ..< pkgPart.len - 1]
    for raw2 in inner.split(','):
      let n = raw2.strip()
      if n.len == 0: continue
      result.packages.add(n)
    if result.packages.len == 0:
      raise newException(SourceSpecError,
        "dnf source spec brace group is empty: " & raw)
  else:
    result.packages.add(pkgPart.strip())

  for f, val in fieldPairs(result):
    when val is string:
      if val.len == 0:
        raise newException(SourceSpecError,
          "dnf source spec has empty " & f & ": " & raw)
  if result.distro notin KnownDnfDistros:
    raise newException(SourceSpecError,
      "dnf source spec distro '" & result.distro &
      "' is not in the known set " & $KnownDnfDistros)

# ---------------------------------------------------------------------------
# URL templates
# ---------------------------------------------------------------------------

const DefaultUpstream* = "kojipkgs.fedoraproject.org"
  ## Default host the harvester points at when the operator omits
  ## ``--upstream``. snapshot/compose archive at
  ## ``/compose/<release>/<snapshot>/compose/Everything/x86_64/os/``.
  ## Vault is also accepted via ``--upstream dl.fedoraproject.org``.

proc snapshotBaseUrl*(spec: DnfSourceSpec;
                     upstream = DefaultUpstream): string =
  ## Returns the snapshot-base URL the harvester fetches from. The
  ## structure differs by upstream:
  ##
  ##   * kojipkgs: ``https://kojipkgs.fedoraproject.org/compose/<release>/<snap>/compose/Everything/x86_64/os``
  ##   * vault   : ``https://dl.fedoraproject.org/pub/archive/fedora/linux/releases/<release>/Everything/x86_64/os``
  ##
  ## The compose layout puts ``repodata/`` directly under the base. The
  ## vault layout matches it. Both expose the same ``repodata/repomd.xml``
  ## entry point.
  if upstream.contains("dl.fedoraproject.org") or upstream.contains("vault"):
    return "https://" & upstream & "/pub/archive/fedora/linux/releases/" &
      spec.release & "/Everything/x86_64/os"
  # Default: kojipkgs compose path.
  return "https://" & upstream & "/compose/" & spec.release & "/" &
    spec.snapshot & "/compose/Everything/x86_64/os"

proc repomdUrl*(spec: DnfSourceSpec; upstream = DefaultUpstream): string =
  spec.snapshotBaseUrl(upstream) & "/repodata/repomd.xml"

proc canonicalSnapshotPin*(spec: DnfSourceSpec): string =
  ## Returns the snapshot pin string the catalog files store. Matches
  ## the B1 grammar (3 segments) required for foreign-bundle PackageRef:
  ## ``<distro>/<release>/<snapshot>``.
  spec.distro & "/" & spec.release & "/" & spec.snapshot
