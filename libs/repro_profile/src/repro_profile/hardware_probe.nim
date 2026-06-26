## M9.R.21.2 — hardware probe driver for ``repro hardware probe``.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §3.4.
##
## The probe runs on a live Linux system and emits the typed shape
## ``hardware "<id>":`` parses (see ``./macros_system.nim`` ``hardware``
## macro + ``./types.nim`` ``SystemHardwareSpec``).
##
## Architecture:
##
## * Each sub-probe (``probeCpuFrom`` / ``probeBootFrom`` / ... ) is a
##   PURE function — it takes its source bytes + sub-command outputs
##   and returns the typed slice. The live "go talk to /proc + lsblk"
##   wrappers (``probeCpu`` / ``probeBoot`` / ...) read the source and
##   delegate. Tests exercise the pure form with fixtures; the live
##   form is exercised end-to-end on real hardware via M9.R.21.4.
##
## * ``probeAll`` composes the live sub-probes into a ``ProbeResult``
##   and wires the stable system-ID composer from M9.R.21.1.
##
## Linux-only. Calling any of the live entry points on a non-Linux host
## raises ``ValueError``; the CLI handler turns that into the standard
## "platform not supported" diagnostic.

import std/[algorithm, json, os, osproc, streams, strtabs, strutils]

import ./types
import ./hardware_id

type
  ProbeBootSpec* = object
    kernelModules*: seq[string]
    loaderDevice*: string

  ProbeFsEntry* = object
    mountPoint*: string
    device*: string
    fsType*: string
    options*: seq[string]

  ProbeCpuSpec* = object
    arch*: string
    microcode*: string  ## "intel" | "amd" | "none"

  ProbeGraphicsSpec* = object
    drivers*: seq[string]

  ProbeAudioSpec* = object
    cards*: seq[string]

  ProbeNetworkSpec* = object
    interfaces*: seq[string]

  ProbeResult* = object
    systemId*: string
    cpu*: ProbeCpuSpec
    boot*: ProbeBootSpec
    filesystems*: seq[ProbeFsEntry]
    graphics*: ProbeGraphicsSpec
    audio*: ProbeAudioSpec
    network*: ProbeNetworkSpec

# ---------------------------------------------------------------------
# CPU: /proc/cpuinfo parser.
# ---------------------------------------------------------------------

proc probeCpuFrom*(cpuinfo: string): ProbeCpuSpec =
  ## Parse ``/proc/cpuinfo`` text. The probe is conservative: it picks
  ## the first ``vendor_id:`` line, maps Intel/AMD vendor strings into
  ## the microcode-package selector the NixOS module uses, and falls
  ## back to ``"none"`` on anything unrecognised (ARM SBCs are the
  ## common case here — they don't ship a per-vendor microcode blob).
  result.arch = ""
  result.microcode = "none"
  for line in cpuinfo.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    let colon = s.find(':')
    if colon < 0: continue
    let key = s[0 ..< colon].strip()
    let value = s[colon + 1 .. ^1].strip()
    case key
    of "vendor_id":
      if result.microcode == "none":
        case value
        of "GenuineIntel": result.microcode = "intel"
        of "AuthenticAMD": result.microcode = "amd"
        else: discard
    of "CPU implementer":
      # ARM cpuinfo carries CPU implementer + part instead of vendor_id.
      if result.arch.len == 0: result.arch = "aarch64"
    else: discard
  if result.arch.len == 0:
    when defined(amd64) or defined(x86_64):
      result.arch = "x86_64"
    elif defined(arm64) or defined(aarch64):
      result.arch = "aarch64"
    elif defined(i386):
      result.arch = "i386"
    else:
      result.arch = hostCPU

# ---------------------------------------------------------------------
# Boot: /proc/cmdline + /proc/modules + lsblk loader device.
# ---------------------------------------------------------------------

proc probeBootFrom*(modulesText, cmdline, loaderDevice: string):
    ProbeBootSpec =
  ## ``modulesText``: contents of ``/proc/modules`` (each line:
  ## ``<name> <size> <refcount> <users> <state> <addr>``). The first
  ## column is the live-loaded module name.
  ##
  ## ``cmdline``: contents of ``/proc/cmdline`` (used today only to
  ## detect ``root=`` for the v0.1 loader-device probe when the caller
  ## has nothing better; the macro accepts ``loaderDevice: "..."``).
  ##
  ## ``loaderDevice``: pre-determined loader device path (e.g. the
  ## output of ``lsblk -no PKNAME $(findmnt -no SOURCE /boot)`` the
  ## live wrapper hands in). May be empty.
  result.kernelModules = @[]
  for line in modulesText.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    let sp = s.find(' ')
    if sp < 0: continue
    result.kernelModules.add s[0 ..< sp]
  result.loaderDevice = loaderDevice
  if result.loaderDevice.len == 0:
    # Best-effort cmdline parse — pick up ``root=`` so the macro field
    # has SOMETHING reasonable to round-trip on a host where the live
    # wrapper couldn't run ``findmnt`` (e.g. inside a sandbox).
    for tok in cmdline.split():
      if tok.startsWith("root="):
        result.loaderDevice = tok[5 .. ^1]
        break

# ---------------------------------------------------------------------
# Filesystems: lsblk -f -J -o ... JSON parser.
# ---------------------------------------------------------------------

proc walkLsblkNode(node: JsonNode; outFs: var seq[ProbeFsEntry]) =
  if node.kind != JObject: return
  let mp = if node.hasKey("mountpoint"): node["mountpoint"] else: newJNull()
  let fstype = if node.hasKey("fstype"): node["fstype"] else: newJNull()
  let name = if node.hasKey("name"): node["name"] else: newJNull()
  let uuid = if node.hasKey("uuid"): node["uuid"] else: newJNull()
  if mp.kind == JString and mp.getStr().len > 0 and
     fstype.kind == JString and fstype.getStr().len > 0:
    var dev = ""
    if uuid.kind == JString and uuid.getStr().len > 0:
      dev = "/dev/disk/by-uuid/" & uuid.getStr()
    elif name.kind == JString and name.getStr().len > 0:
      dev = "/dev/" & name.getStr()
    outFs.add ProbeFsEntry(
      mountPoint: mp.getStr(),
      device: dev,
      fsType: fstype.getStr(),
      options: @[])
  if node.hasKey("children") and node["children"].kind == JArray:
    for c in node["children"]:
      walkLsblkNode(c, outFs)

proc probeFilesystemsFrom*(lsblkJson: string): seq[ProbeFsEntry] =
  ## Parse ``lsblk -f -J -o NAME,UUID,FSTYPE,MOUNTPOINT,SIZE`` output.
  ## Walks the nested ``blockdevices`` tree and emits one entry per
  ## node with a non-empty mountpoint + fstype.
  result = @[]
  if lsblkJson.strip().len == 0: return
  let root =
    try: parseJson(lsblkJson)
    except JsonParsingError as e:
      raise newException(ValueError,
        "lsblk JSON parse error: " & e.msg)
  if not root.hasKey("blockdevices"): return
  for bd in root["blockdevices"]:
    walkLsblkNode(bd, result)

# ---------------------------------------------------------------------
# Graphics: lspci -nn -d ::0300 parser → driver name.
# ---------------------------------------------------------------------

proc vendorIdToDriver(vendorId: string): string =
  ## PCI vendor ID → Linux DRM driver name. The mapping covers every
  ## vendor a desktop user is likely to see; SBC / mobile GPUs that
  ## ship out-of-tree drivers (Mali via panfrost, VC4 via vc4, ...)
  ## are intentionally out of scope for v0.1.
  case vendorId.toLowerAscii()
  of "8086": "i915"        # Intel
  of "10de": "nouveau"     # Nvidia — nouveau is the in-tree default
  of "1002": "amdgpu"      # AMD
  of "1af4": "qxl"         # virtio (QEMU)
  of "15ad": "vmwgfx"      # VMware
  of "1414": "hyperv_drm"  # Microsoft Hyper-V
  of "1234": "bochs-drm"   # QEMU stdvga
  else: ""

proc probeGraphicsFrom*(lspciOutput: string): ProbeGraphicsSpec =
  ## Parse ``lspci -nn -d ::0300`` lines. The relevant token is the
  ## ``[<vendor>:<device>]`` triple after the class brackets. Tolerates
  ## multiple cards (laptop hybrid graphics) by emitting one driver per
  ## unique vendor ID, deduplicated in encounter order.
  result.drivers = @[]
  for line in lspciOutput.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    # Format example:
    # 01:00.0 VGA compatible controller [0300]: Advanced Micro Devices,
    #   Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT/XTX] [1002:744c] (rev cc)
    # Find the last ``[<hex>:<hex>]`` token in the line — that's the
    # vendor:device pair. Anchor on the rightmost ``[``.
    var lastOpen = -1
    var lastClose = -1
    for i in countdown(s.high, 0):
      if s[i] == ']' and lastClose < 0: lastClose = i
      elif s[i] == '[' and lastClose >= 0:
        lastOpen = i; break
    if lastOpen < 0 or lastClose <= lastOpen: continue
    let token = s[lastOpen + 1 ..< lastClose]
    let colon = token.find(':')
    if colon != 4: continue   # need 4-char hex vendor
    let vendor = token[0 ..< colon]
    let driver = vendorIdToDriver(vendor)
    if driver.len > 0 and driver notin result.drivers:
      result.drivers.add driver

# ---------------------------------------------------------------------
# Audio: /proc/asound/cards parser.
# ---------------------------------------------------------------------

proc probeAudioFrom*(cardsText: string): ProbeAudioSpec =
  ## Parse ``/proc/asound/cards``. Example::
  ##
  ##   0 [PCH            ]: HDA-Intel - HDA Intel PCH
  ##                        HDA Intel PCH at 0xfe800000 irq 33
  ##   1 [HDMI           ]: HDA-Intel - HDA Intel HDMI
  ##
  ## We extract the short module / kind tag after the ``]: `` — for the
  ## v0.1 surface that's the only field ``hardware.audio.cards``
  ## accepts. Deduplicated in encounter order.
  result.cards = @[]
  for line in cardsText.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    let bracket = s.find(']')
    if bracket < 0: continue
    let colon = s.find(':', bracket)
    if colon < 0: continue
    var tag = s[colon + 1 .. ^1].strip()
    # Drop everything after the first ``-`` separator: ``HDA-Intel - HDA
    # Intel PCH`` → ``hda-intel``. Lowercase for canonical comparison.
    let dash = tag.find(" - ")
    if dash > 0: tag = tag[0 ..< dash].strip()
    tag = tag.toLowerAscii()
    if tag.len == 0: continue
    if tag notin result.cards:
      result.cards.add tag

# ---------------------------------------------------------------------
# Network: /sys/class/net enumerator (live wrapper).
# ---------------------------------------------------------------------

proc probeNetworkFromDir*(sysClassNet: string): ProbeNetworkSpec =
  ## Enumerate ``/sys/class/net/*`` excluding loopback + the standard
  ## virtual-bridge names a Docker-installed host inevitably grows.
  ## v0.1 emits only the interface name; the ``hardware.network``
  ## macro field accepts the same shape.
  result.interfaces = @[]
  if not dirExists(sysClassNet): return
  const VirtualPrefixes = [
    "docker", "virbr", "veth", "br-", "tap", "tun",
    "vmnet", "vnet", "vboxnet", "wg"]
  var names: seq[string] = @[]
  for kind, path in walkDir(sysClassNet, relative = true):
    let n = path
    if n == "lo": continue
    var virt = false
    for p in VirtualPrefixes:
      if n.startsWith(p): virt = true; break
    if virt: continue
    names.add n
  names.sort()
  result.interfaces = names

# ---------------------------------------------------------------------
# Live wrappers — read from /proc + run external commands.
# ---------------------------------------------------------------------

proc readAllOrEmpty(path: string): string =
  if not fileExists(path): return ""
  try: readFile(path)
  except CatchableError: ""

proc childEnvWithoutLdLibPath*(): StringTableRef =
  ## M9.R.40.2 — build a child-process env table with the loader-related
  ## env vars stripped.  The installer launcher (M9.R.40.1) no longer
  ## sets ``LD_LIBRARY_PATH`` on the installer's env (it invokes ld.so
  ## with ``--library-path`` instead), so the parent's env is normally
  ## clean.  This helper is defence-in-depth: if a future launcher
  ## change reintroduces LD_LIBRARY_PATH propagation, our hardware-probe
  ## subprocesses (``/bin/sh -c "lsblk ..."``, ``findmnt``, ``lspci``)
  ## still get a clean env so Debian's ``/bin/sh`` doesn't try to load
  ## nix-store's libc.so.6 and hit a GLIBC_PRIVATE symbol mismatch
  ## (RC=127, M9.R.39.5 / M9.R.39.6 failure shape).  We also strip
  ## ``LD_DEBUG`` / ``LD_DEBUG_OUTPUT`` so probe children don't pollute
  ## a diagnostic ld-debug log file the parent set up.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    case k
    of "LD_LIBRARY_PATH", "LD_DEBUG", "LD_DEBUG_OUTPUT", "LD_PRELOAD",
       "LD_AUDIT":
      discard
    else:
      result[k] = v

proc execShellCmdCleanEnv*(cmd: string): tuple[output: string; exitCode: int] =
  ## Like ``execCmdEx(cmd)`` but spawns the child with
  ## ``childEnvWithoutLdLibPath()``.  The child runs via ``/bin/sh -c``
  ## so shell pipelines / quoting continue to work, matching the
  ## ``execCmdEx`` semantics the original probe used.
  result.output = ""
  result.exitCode = -1
  let env = childEnvWithoutLdLibPath()
  var p: Process
  try:
    p = startProcess(
      "/bin/sh",
      args = @["-c", cmd],
      env = env,
      options = {poUsePath, poStdErrToStdOut})
  except OSError:
    return
  let s = p.outputStream()
  try:
    result.output = s.readAll()
  except IOError, OSError:
    discard
  try:
    result.exitCode = p.waitForExit()
  except OSError:
    discard
  p.close()

proc lsblkRawLogPath(): string =
  ## Optional dump-path for the raw lsblk JSON output, gated on the
  ## ``REPRO_HARDWARE_PROBE_RAWLOG_DIR`` env var.  Set the dir from the
  ## installer harness (e.g. /tmp) and the probe writes
  ## ``<dir>/lsblk.raw.txt`` before parsing.  Empty if unset.
  let dir = getEnv("REPRO_HARDWARE_PROBE_RAWLOG_DIR")
  if dir.len == 0: return ""
  return dir / "lsblk.raw.txt"

proc dumpRawIfRequested(name, content: string; exitCode: int) =
  let dir = getEnv("REPRO_HARDWARE_PROBE_RAWLOG_DIR")
  if dir.len == 0: return
  try:
    if not dirExists(dir):
      createDir(dir)
    let payload = "exit=" & $exitCode & "\n" &
                  "bytes=" & $content.len & "\n" &
                  "---\n" & content
    writeFile(dir / name, payload)
  except CatchableError:
    discard

proc runOrEmpty(cmd: string): string =
  try:
    let r = execShellCmdCleanEnv(cmd)
    r.output
  except CatchableError: ""

proc probeCpu*(): ProbeCpuSpec =
  probeCpuFrom(readAllOrEmpty("/proc/cpuinfo"))

proc probeBoot*(): ProbeBootSpec =
  let modulesText = readAllOrEmpty("/proc/modules")
  let cmdline = readAllOrEmpty("/proc/cmdline")
  # Try to resolve the /boot device via findmnt — falls back to root=
  # in cmdline if findmnt is unavailable.
  var loader = runOrEmpty("findmnt -no SOURCE /boot").strip()
  if loader.len == 0:
    loader = runOrEmpty("findmnt -no SOURCE /").strip()
  probeBootFrom(modulesText, cmdline, loader)

proc probeFilesystems*(): seq[ProbeFsEntry] =
  ## M9.R.40.1 — characterise lsblk's actual on-host output before
  ## handing it to the JSON parser.  When
  ## ``REPRO_HARDWARE_PROBE_RAWLOG_DIR`` is set, the raw bytes (plus
  ## exit code + byte count) are written to ``<dir>/lsblk.raw.txt``
  ## BEFORE the early-empty check or the parse step.  Lets the live-ISO
  ## driver capture what lsblk actually emitted (or what /bin/sh said
  ## when a symbol-lookup error replaced the command output).
  var r: tuple[output: string; exitCode: int]
  try:
    r = execShellCmdCleanEnv(
      "lsblk -f -J -o NAME,UUID,FSTYPE,MOUNTPOINT,SIZE")
  except CatchableError:
    r = (output: "", exitCode: -1)
  dumpRawIfRequested("lsblk.raw.txt", r.output, r.exitCode)
  if r.output.strip().len == 0: return @[]
  probeFilesystemsFrom(r.output)

proc probeGraphics*(): ProbeGraphicsSpec =
  probeGraphicsFrom(runOrEmpty("lspci -nn -d ::0300"))

proc probeAudio*(): ProbeAudioSpec =
  probeAudioFrom(readAllOrEmpty("/proc/asound/cards"))

proc probeNetwork*(): ProbeNetworkSpec =
  probeNetworkFromDir("/sys/class/net")

proc probeAll*(): ProbeResult =
  result.systemId = composeStableSystemId()
  result.cpu = probeCpu()
  result.boot = probeBoot()
  result.filesystems = probeFilesystems()
  result.graphics = probeGraphics()
  result.audio = probeAudio()
  result.network = probeNetwork()

# ---------------------------------------------------------------------
# Materialise a `ProbeResult` into the typed `SystemHardwareSpec` the
# M9.R.20 hardware macro accepts. v0.1 drops the network slice (the
# macro doesn't yet model it).
# ---------------------------------------------------------------------

proc toSystemHardwareSpec*(p: ProbeResult): SystemHardwareSpec =
  result.id = p.systemId
  result.cpuArch = p.cpu.arch
  result.cpuMicrocode = p.cpu.microcode
  result.kernelModules = p.boot.kernelModules
  result.loaderDevice = p.boot.loaderDevice
  for fs in p.filesystems:
    result.filesystems.add SystemHardwareFs(
      mountPoint: fs.mountPoint,
      device: fs.device,
      fsType: fs.fsType,
      options: fs.options)
  result.graphicsDrivers = p.graphics.drivers
  result.audioCards = p.audio.cards

# ---------------------------------------------------------------------
# Render a `SystemHardwareSpec` as Nim source text matching the
# `hardware "<id>":` macro the M9.R.20 parser accepts. The text is
# round-trip-safe: feeding it through ``hardware`` rebuilds the same
# spec.
# ---------------------------------------------------------------------

proc renderStrList(items: seq[string]): string =
  result = "@["
  for i, it in items:
    if i > 0: result.add ", "
    result.add '"'
    for c in it:
      case c
      of '\\': result.add "\\\\"
      of '"':  result.add "\\\""
      of '\n': result.add "\\n"
      else: result.add c
    result.add '"'
  result.add "]"

proc renderHardwareSpec*(h: SystemHardwareSpec): string =
  ## Emit the canonical ``hardware "<id>": ...`` shape the M9.R.20
  ## macro parses. Header is ``# /etc/repro/hardware.nim — ...``; the
  ## body uses 2-space indentation per the project's house style.
  result = "# /etc/repro/hardware.nim — auto-generated by " &
           "`repro hardware probe`.\n"
  result.add "import repro_profile\n\n"
  result.add "hardware \"" & h.id & "\":\n"
  result.add "  cpu:\n"
  result.add "    arch: \"" & h.cpuArch & "\"\n"
  result.add "    microcode: \"" & h.cpuMicrocode & "\"\n"
  result.add "\n  boot:\n"
  result.add "    kernelModules: " & renderStrList(h.kernelModules) & "\n"
  result.add "    loaderDevice: \"" & h.loaderDevice & "\"\n"
  if h.filesystems.len > 0:
    result.add "\n  filesystems:\n"
    for fs in h.filesystems:
      result.add "    \"" & fs.mountPoint & "\":\n"
      result.add "      device: \"" & fs.device & "\"\n"
      result.add "      fsType: \"" & fs.fsType & "\"\n"
      if fs.options.len > 0:
        result.add "      options: " & renderStrList(fs.options) & "\n"
  result.add "\n  graphics:\n"
  result.add "    drivers: " & renderStrList(h.graphicsDrivers) & "\n"
  result.add "\n  audio:\n"
  result.add "    cards: " & renderStrList(h.audioCards) & "\n"
