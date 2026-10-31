## Generation 0: the add-on's own objects.
##
## Bootstrap's last step applies one generation through ``repro infra
## apply``, the same path every later generation takes; bootstrap has no
## apply code of its own. That generation contains only what the add-on
## needs to exist on the host:
##
## - ``repro-addon.target``: the target the add-on's units hang off, wanted
##   by ``multi-user.target``. Nothing of the base ``Requires=`` it, so a
##   broken add-on cannot hold up the base's boot;
## - ``repro-store.mount``: ``/repro/store`` bind-mounted read-only over
##   itself, so no process on the host can write the store through the
##   ordinary mount namespace (the apply process gets a private writable
##   view; see ``store_root.withWritableStore``);
## - ``repro-addon-reassert.service``: at boot, finishes or reverts an
##   interrupted switch and reports whether every ledger object still
##   matches its digest. It never re-applies on drift, and it has no
##   network;
## - the apt hook ``/etc/apt/apt.conf.d/90repro-addon``: a report-only
##   ``DPkg::Post-Invoke`` that can never fail a dpkg run, even when the
##   binary it names is missing;
## - ``/etc/profile.d/repro-addon.sh``: the add-on's ``repro`` on ``PATH``
##   (appended). The profile DSL's ``addOnToolPath()`` writes a file of its
##   own, ``/etc/profile.d/repro-addon-tools.sh`` (``repro_profile``
##   ``AddOnToolPathFile``): one file, one writer -- spec §4.1;
## - the trust anchors under ``/etc/repro/anchors``.
##
## Every path here must be absent before bootstrap (the preflight checks
## it), which is what makes "bootstrap changes nothing pre-existing" a
## property of this list rather than a hope. The pre-bootstrap inputs the
## preflight takes over (spec §6.1) are never on this list.
##
## The text this module renders is the canonical system-profile text
## ``repro infra apply`` parses (``repro_infra/profile.parseSystemProfile``).
## That format has no escapes, so file bodies are not written inline: each
## is a content-addressed file in the add-on's own store prefix, named by
## its SHA-256 and referenced with ``sourceLocal``. Unit bodies are inline,
## and ``assertInlineSafe`` refuses any character the format cannot carry
## rather than letting the parser misread it.

import std/[algorithm, strutils]

import repro_elevation/posix_system_parse

import ./fingerprint
import ./mutations

type
  OwnObjectKind* = enum
    ookUnit, ookEtcFile

  OwnObject* = object
    kind*: OwnObjectKind
    path*: string        ## absolute target path
    unit*: string        ## unit name (ookUnit)
    content*: string
    enabled*: bool       ## ookUnit: ``systemctl enable --now``

  Gen0Inputs* = object
    reproExe*: string           ## the add-on's ``repro`` inside the store
    deploySigners*: seq[string] ## deploy-manifest signer keys (hex), canonical
    cacheUrl*: string           ## the binary cache to substitute from, or ""
    cachePublishers*: seq[string] ## the only producer keys trusted for it

const
  SystemdUnitDir* = "/etc/systemd/system"
  AddonTarget* = "repro-addon.target"
  StoreMountUnit* = "repro-store.mount"
  ReassertUnit* = "repro-addon-reassert.service"
  AptHookPath* = "/etc/apt/apt.conf.d/90repro-addon"
  ProfileDPath* = "/etc/profile.d/repro-addon.sh"
  AnchorsDir* = "/etc/repro/anchors"
  DeploySignersPath* = AnchorsDir & "/deploy-signers.anchors"
  CachesConfPath* = "/etc/repro/caches.conf"
    ## The system binary-cache client configuration (``repro_binary_cache_client
    ## /caches_config``): the cache list every substitution on the host reads,
    ## each cache with the only producer keys trusted for it.
  StoreRoot* = "/repro/store"

proc unitPath*(name: string): string =
  ## The unit file the driver writes for ``name``: the driver's own
  ## derivation (``systemUnitPath``), so what the collision pass observes
  ## and what the write lands on are one string by construction.
  systemUnitPath(name)

proc assertInlineSafe*(what, text: string) =
  ## The canonical profile text has no escapes: a double quote ends the
  ## value, ``#`` on a continuation line starts a comment, and a brace can
  ## end the stanza. A unit body containing one would be silently misread,
  ## so it is refused here instead.
  for c in text:
    if c in {'"', '#', '{', '}', '\\'}:
      raise newException(ValueError, what & " contains '" & c &
        "', which the canonical system-profile text cannot carry inline")

proc targetUnit(): string =
  """[Unit]
Description=Reprobuild add-on services
Documentation=man:systemd.special(7)

[Install]
WantedBy=multi-user.target
"""

proc storeMountUnit(): string =
  # A bind mount of the store over itself, read-only. ``DefaultDependencies``
  # stays on: this is not needed early, and leaving it on keeps the mount out
  # of the base's local-fs.target.
  """[Unit]
Description=Reprobuild add-on store, read-only
RequiresMountsFor=/repro
Before=repro-addon.target

[Mount]
What=/repro/store
Where=/repro/store
Type=none
Options=bind,ro

[Install]
WantedBy=repro-addon.target
"""

proc reassertUnit(reproExe: string): string =
  # Boot-time re-assertion (§7.7): finishes or reverts an interrupted
  # switch, checks the current generation and reports ok / drift /
  # degraded. It never re-applies on drift.
  #
  # It must not be able to hold up the base's boot: it is wanted only by
  # the add-on's target, never by multi-user.target, and it is only
  # ORDERED after the store mount (`After=`), never `Requires=` it -- a
  # missing store must still let it run and report `degraded`. For the
  # same reason the binary, which lives in the store, is tested before it
  # is executed: with the store gone the shell reports `degraded` itself
  # instead of the unit failing silently with ENOENT. `reassert --boot`
  # always exits 0. No network: it needs none, and its health probes run
  # in the host's namespaces through PID 1.
  when mutated("reassert-required-by-boot"):
    # The falsifying mutation: in the base's boot path, and requiring the
    # store mount, so a missing store fails the unit before it can report.
    let unitDeps = "Requires=repro-store.mount\n" &
                   "After=local-fs.target repro-store.mount\n"
    let wantedBy = "multi-user.target"
  else:
    let unitDeps = "After=local-fs.target repro-store.mount\n" &
                   "Before=repro-addon.target\n"
    let wantedBy = "repro-addon.target"
  "[Unit]\n" &
  "Description=Reprobuild add-on boot-time re-assertion\n" &
  unitDeps &
  "\n" &
  "[Service]\n" &
  "Type=oneshot\n" &
  "RemainAfterExit=yes\n" &
  "TimeoutStartSec=15min\n" &
  "ExecStart=/bin/sh -c 'if [ -x " & reproExe & " ]; then exec " & reproExe &
    " system addon reassert --boot; else echo repro-addon reassert: " &
    "degraded: the add-on binary " & reproExe & " is unavailable, the " &
    "store is missing or unreadable; fi'\n" &
  "PrivateNetwork=yes\n" &
  "NoNewPrivileges=yes\n" &
  "ProtectHome=yes\n" &
  "PrivateTmp=yes\n" &
  "\n" &
  "[Install]\n" &
  "WantedBy=" & wantedBy & "\n"

proc aptHook(reproExe: string): string =
  # Report-only by construction: the whole hook is one shell command that
  # tests for the binary and ends in ``|| true``, so a missing store, a
  # missing binary or a failing verification can never fail dpkg or
  # unattended-upgrades.
  "// Reprobuild add-on: report-only verification after every dpkg run.\n" &
  "// It never fails dpkg: the command always exits 0.\n" &
  "DPkg::Post-Invoke { \"if [ -x " & reproExe & " ]; then " & reproExe &
    " system addon verify --after-dpkg || true; fi\"; };\n"

proc profileD(reproExe: string): string =
  let bindir = reproExe[0 ..< reproExe.rfind('/')]
  "# Reprobuild add-on: put the add-on's repro on PATH.\n" &
  "case \":$PATH:\" in\n" &
  "  *\":" & bindir & ":\"*) ;;\n" &
  "  *) PATH=\"$PATH:" & bindir & "\" ;;\n" &
  "esac\n"

proc isPublicKeyHex*(s: string): bool =
  ## A 65-byte uncompressed ECDSA-P256 public key in lower- or upper-case
  ## hex (the anchor-file and ``caches.conf`` spelling).
  s.len == 130 and s[0 .. 1] == "04" and s.allCharsInSet(HexDigits)

proc parseAnchorKeys*(text, what: string): seq[string] =
  ## The keys of an anchor file (one hex key per line, ``#`` comments),
  ## lower-cased, de-duplicated and sorted, so the same set always renders
  ## to the same bytes. A malformed line raises.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    if not isPublicKeyHex(line):
      raise newException(ValueError, what & ": not an uncompressed P-256 " &
        "public key in hex: " & line)
    let k = line.toLowerAscii()
    if k notin result: result.add(k)
  result.sort()

proc renderAnchors*(keys: seq[string]): string =
  ## The deploy-signer anchor file, in the format the deploy agent's
  ## ``--allowed-signers`` reads (``repro_peer_cache/auth.loadTrustAnchors``).
  result = "# Reprobuild add-on: deploy-manifest signers this host accepts.\n"
  for k in keys: result.add(k & "\n")

proc renderCachesConf*(url: string; keys: seq[string]): string =
  ## ``/etc/repro/caches.conf`` holding exactly one cache, trusted for
  ## exactly the publisher anchors given at bootstrap. With no cache, the
  ## file lists none, and the default-untrusted client substitutes nothing.
  ## A cache without a key would be one nothing may be substituted from, so
  ## it is refused rather than written.
  result = "# Reprobuild add-on: the binary cache this host substitutes from,\n" &
           "# and the only producer keys trusted for it (default-untrusted).\n"
  if url.len == 0:
    if keys.len > 0:
      raise newException(ValueError, "cache publisher anchors were given " &
        "without a cache URL")
    result.add("# No cache is configured: nothing is substituted.\n")
    return
  if keys.len == 0:
    raise newException(ValueError, "a cache URL was given without publisher " &
      "anchors; under default-untrusted it could never be used")
  if not (url.startsWith("https://") or url.startsWith("http://")) or
      url.find({' ', '"', '\n', '\r', '\t'}) >= 0:
    raise newException(ValueError, "invalid cache URL: " & url)
  result.add("[addon]\n")
  result.add("url = \"" & url & "\"\n")
  result.add("trusted-public-keys = \"" & keys.join(", ") & "\"\n")

proc generation0Objects*(inp: Gen0Inputs): seq[OwnObject] =
  ## The add-on's own objects, in apply order: the target first (the other
  ## units are wanted by it), the mount before the unit that is ordered
  ## after it.
  if inp.reproExe.len == 0 or not inp.reproExe.startsWith(StoreRoot & "/"):
    raise newException(ValueError,
      "generation 0 needs the add-on's repro inside " & StoreRoot &
      ", got '" & inp.reproExe & "'")
  result = @[
    OwnObject(kind: ookEtcFile, path: DeploySignersPath,
              content: renderAnchors(inp.deploySigners)),
    OwnObject(kind: ookEtcFile, path: CachesConfPath,
              content: renderCachesConf(inp.cacheUrl, inp.cachePublishers)),
    OwnObject(kind: ookUnit, unit: AddonTarget, path: unitPath(AddonTarget),
              content: targetUnit(), enabled: true),
    OwnObject(kind: ookUnit, unit: StoreMountUnit,
              path: unitPath(StoreMountUnit), content: storeMountUnit(),
              enabled: true),
    OwnObject(kind: ookUnit, unit: ReassertUnit, path: unitPath(ReassertUnit),
              content: reassertUnit(inp.reproExe), enabled: true),
    OwnObject(kind: ookEtcFile, path: AptHookPath,
              content: aptHook(inp.reproExe)),
    OwnObject(kind: ookEtcFile, path: ProfileDPath,
              content: profileD(inp.reproExe)),
  ]

proc contentFileName*(o: OwnObject): string =
  ## The file under the generation's files prefix that holds ``o``'s body.
  sha256Hex(o.content)

proc renderOwnProfile*(objects: seq[OwnObject]; filesDir: string): string =
  ## Canonical system-profile text for the add-on's own objects. File
  ## bodies are read from ``filesDir/<sha256>``.
  for o in objects:
    case o.kind
    of ookEtcFile:
      result.add("fs.systemFile {\n")
      result.add("  path = \"" & o.path & "\"\n")
      result.add("  sourceLocal = \"" & filesDir & "/" & contentFileName(o) &
                 "\"\n")
      result.add("}\n\n")
    of ookUnit:
      assertInlineSafe("unit " & o.unit, o.content)
      result.add("systemd.systemUnit {\n")
      result.add("  name = \"" & o.unit & "\"\n")
      result.add("  content = \"" & o.content & "\"\n")
      result.add("  enabled = " & (if o.enabled: "true" else: "false") & "\n")
      result.add("}\n\n")

proc ownObjectPaths*(objects: seq[OwnObject]): seq[string] =
  ## Every path generation 0 writes, sorted: the preflight requires all of
  ## them to be absent.
  for o in objects:
    result.add(o.path)
  result.sort()

proc installTargets*(unitContent: string): seq[tuple[kind, target: string]] =
  ## Every ``[Install]`` directive of a unit (systemd.unit(5) "[Install]
  ## Section Options", systemd 252-260): ``WantedBy`` / ``RequiredBy`` /
  ## ``UpheldBy`` (a symlink in ``<target>.wants`` / ``.requires`` /
  ## ``.upholds``), ``Alias`` (a symlink with the alias name), and the two
  ## that make ``systemctl enable`` do more than link this unit: ``Also``
  ## (enable those units too) and ``DefaultInstance`` (the instance a
  ## template is enabled as). Space-separated lists are split; the caller
  ## decides what each kind may do.
  when mutated("install-targets-ignore-alias-also"):
    const known = ["WantedBy", "RequiredBy"]
  else:
    const known = ["WantedBy", "RequiredBy", "UpheldBy", "Alias", "Also",
                   "DefaultInstance"]
  var inInstall = false
  for raw in unitContent.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inInstall = line == "[Install]"
      continue
    if not inInstall or line.len == 0 or line[0] in {'#', ';'}:
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip()
    if key in known:
      for v in line[eq + 1 .. ^1].splitWhitespace():
        result.add((kind: key, target: v))

proc hasInstallSection*(unitContent: string): bool =
  for raw in unitContent.splitLines():
    if raw.strip() == "[Install]": return true
  false

proc mountWhere*(unitContent: string): string =
  ## ``Where=`` of a ``.mount`` unit, "" if none.
  var inMount = false
  for raw in unitContent.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inMount = line == "[Mount]"
      continue
    if inMount and line.startsWith("Where="):
      return line["Where=".len .. ^1].strip()
  ""
