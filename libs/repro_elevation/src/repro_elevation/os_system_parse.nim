## Pure parse + drift logic for the post-M83 cross-platform OS-scope
## drivers: `os.timezone` and `os.hostname`.
##
## Per the established M68 Phase A / M69 Phase C precedent: every real
## syscall / shell-out lives behind `when defined(linux | macosx |
## windows)` in `windows_system_driver.nim` / `posix_system_driver.nim`;
## the PURE logic — the IANA-to-Windows timezone mapping table, the
## canonical-state digests, and the hostname charset guard — is
## isolated here so it is unit-tested cross-platform without touching
## the host. No `import std/os`, no `osproc`, no syscalls — this
## module is platform-pure by construction.

import std/[strutils]

# ===========================================================================
# os.timezone — IANA <-> Windows timezone name mapping.
#
# Windows' `tzutil` takes a Windows-flavoured timezone name (e.g.
# `FLE Standard Time`), not the IANA tz database name (e.g.
# `Europe/Sofia`). Microsoft maintains a canonical IANA <-> Windows
# mapping in the CLDR "windowsZones.xml" data, mirrored into the
# Windows ICU. We embed a small subset covering the common cases the
# user profile needs; an unmapped IANA name fails closed at validation
# time with a clear "extend the mapping table" diagnostic so the
# driver never reaches `tzutil` with an unsupported name.
# ===========================================================================

type
  IanaWindowsTzMapping* = tuple[iana: string, windows: string]
    ## One entry in the embedded IANA <-> Windows mapping table.

const IanaToWindowsTzTable*: seq[IanaWindowsTzMapping] = @[
  # UTC / GMT.
  (iana: "Etc/UTC", windows: "UTC"),
  (iana: "UTC", windows: "UTC"),
  (iana: "Etc/GMT", windows: "UTC"),
  # Europe.
  (iana: "Europe/London", windows: "GMT Standard Time"),
  (iana: "Europe/Dublin", windows: "GMT Standard Time"),
  (iana: "Europe/Lisbon", windows: "GMT Standard Time"),
  (iana: "Europe/Berlin", windows: "W. Europe Standard Time"),
  (iana: "Europe/Vienna", windows: "W. Europe Standard Time"),
  (iana: "Europe/Rome", windows: "W. Europe Standard Time"),
  (iana: "Europe/Madrid", windows: "Romance Standard Time"),
  (iana: "Europe/Paris", windows: "Romance Standard Time"),
  (iana: "Europe/Brussels", windows: "Romance Standard Time"),
  (iana: "Europe/Amsterdam", windows: "W. Europe Standard Time"),
  (iana: "Europe/Zurich", windows: "W. Europe Standard Time"),
  (iana: "Europe/Stockholm", windows: "W. Europe Standard Time"),
  (iana: "Europe/Warsaw", windows: "Central European Standard Time"),
  (iana: "Europe/Prague", windows: "Central Europe Standard Time"),
  (iana: "Europe/Budapest", windows: "Central Europe Standard Time"),
  (iana: "Europe/Helsinki", windows: "FLE Standard Time"),
  (iana: "Europe/Kiev", windows: "FLE Standard Time"),
  (iana: "Europe/Kyiv", windows: "FLE Standard Time"),
  (iana: "Europe/Sofia", windows: "FLE Standard Time"),
  (iana: "Europe/Athens", windows: "GTB Standard Time"),
  (iana: "Europe/Bucharest", windows: "GTB Standard Time"),
  (iana: "Europe/Istanbul", windows: "Turkey Standard Time"),
  (iana: "Europe/Moscow", windows: "Russian Standard Time"),
  # Americas.
  (iana: "America/New_York", windows: "Eastern Standard Time"),
  (iana: "America/Detroit", windows: "Eastern Standard Time"),
  (iana: "America/Toronto", windows: "Eastern Standard Time"),
  (iana: "America/Chicago", windows: "Central Standard Time"),
  (iana: "America/Denver", windows: "Mountain Standard Time"),
  (iana: "America/Phoenix", windows: "US Mountain Standard Time"),
  (iana: "America/Los_Angeles", windows: "Pacific Standard Time"),
  (iana: "America/Vancouver", windows: "Pacific Standard Time"),
  (iana: "America/Anchorage", windows: "Alaskan Standard Time"),
  (iana: "America/Honolulu", windows: "Hawaiian Standard Time"),
  (iana: "America/Sao_Paulo", windows: "E. South America Standard Time"),
  (iana: "America/Buenos_Aires", windows: "Argentina Standard Time"),
  (iana: "America/Mexico_City", windows: "Central Standard Time (Mexico)"),
  # Asia.
  (iana: "Asia/Tokyo", windows: "Tokyo Standard Time"),
  (iana: "Asia/Seoul", windows: "Korea Standard Time"),
  (iana: "Asia/Shanghai", windows: "China Standard Time"),
  (iana: "Asia/Hong_Kong", windows: "China Standard Time"),
  (iana: "Asia/Singapore", windows: "Singapore Standard Time"),
  (iana: "Asia/Kolkata", windows: "India Standard Time"),
  (iana: "Asia/Calcutta", windows: "India Standard Time"),
  (iana: "Asia/Dubai", windows: "Arabian Standard Time"),
  (iana: "Asia/Jerusalem", windows: "Israel Standard Time"),
  (iana: "Asia/Bangkok", windows: "SE Asia Standard Time"),
  (iana: "Asia/Manila", windows: "Singapore Standard Time"),
  (iana: "Asia/Taipei", windows: "Taipei Standard Time"),
  # Oceania / Pacific.
  (iana: "Australia/Sydney", windows: "AUS Eastern Standard Time"),
  (iana: "Australia/Melbourne", windows: "AUS Eastern Standard Time"),
  (iana: "Australia/Brisbane", windows: "E. Australia Standard Time"),
  (iana: "Australia/Perth", windows: "W. Australia Standard Time"),
  (iana: "Pacific/Auckland", windows: "New Zealand Standard Time"),
  # Africa.
  (iana: "Africa/Cairo", windows: "Egypt Standard Time"),
  (iana: "Africa/Johannesburg", windows: "South Africa Standard Time"),
  (iana: "Africa/Lagos", windows: "W. Central Africa Standard Time"),
  (iana: "Africa/Nairobi", windows: "E. Africa Standard Time"),
  (iana: "Africa/Casablanca", windows: "Morocco Standard Time")
]
  ## The embedded IANA <-> Windows mapping table. Covers the common
  ## cases the user profile and most operator workflows need; an
  ## unmapped IANA name fails closed at validation time, so adding a
  ## new entry is a one-line patch with no implicit fallback.

proc isSafeIanaTimezone*(tz: string): bool =
  ## True for a non-empty IANA-shaped timezone name. The charset is
  ## restricted to alphanumerics, `/`, `_`, `-`, `+`, and `.` — every
  ## character that appears in a real IANA tz database name (including
  ## the legacy `Etc/GMT+10` / `Etc/GMT-5` numerical zones and the
  ## `America/Argentina/Buenos_Aires`-style multi-segment names). A
  ## value with a shell metacharacter is refused outright so the field
  ## cannot smuggle a command past the validator (defence-in-depth
  ## layer 1; the driver `quoteShell`/`psQuote`s the value as layer 2).
  let t = tz.strip()
  if t.len == 0:
    return false
  for ch in t:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '/', '_', '-', '+', '.'}:
      return false
  return true

proc lookupWindowsTimezoneName*(iana: string): string =
  ## Map an IANA timezone name to its Windows equivalent via the
  ## embedded table. Returns the empty string when the name is not in
  ## the table — callers turn an empty result into a closed-set
  ## validation error naming the unmapped IANA value.
  let t = iana.strip()
  for entry in IanaToWindowsTzTable:
    if entry.iana == t:
      return entry.windows
  return ""

proc isMappedIanaTimezone*(iana: string): bool =
  ## True when the IANA name has a Windows mapping in the embedded
  ## table. The closed-set validator gates the `tzutil` shell-out on
  ## this so the driver never reaches the host with an unsupported
  ## name.
  lookupWindowsTimezoneName(iana).len > 0

proc reverseLookupIanaTimezoneName*(windowsName: string;
                                    preferred: string = ""): string =
  ## Map a Windows timezone name back to an IANA name via the embedded
  ## table. The Windows-to-IANA mapping is MANY-TO-ONE — several IANA
  ## zones share a single Windows name (e.g. `Europe/Helsinki`,
  ## `Europe/Kiev`, `Europe/Sofia` all map to `FLE Standard Time`).
  ##
  ## `preferred` is the IANA name the caller would prefer to see when
  ## the Windows name is ambiguous: typically the desired IANA value
  ## from the apply operation. If `preferred` is itself in the table
  ## AND maps to the same Windows name, return `preferred` so a post-
  ## apply re-probe of `Europe/Sofia` -> `FLE Standard Time` returns
  ## `Europe/Sofia` (the operator's stated intent) rather than the
  ## first-table-match `Europe/Helsinki`. When `preferred` is empty
  ## or maps elsewhere (the live tz genuinely differs from desired),
  ## return the first IANA in the table that maps to `windowsName`.
  ## Returns the empty string when `windowsName` is not mapped.
  let w = windowsName.strip()
  if w.len == 0:
    return ""
  let p = preferred.strip()
  if p.len > 0:
    # Walk the table once: if `preferred` is in the table AND maps
    # to `windowsName`, return it (preserves operator intent through
    # the many-to-one ambiguity).
    for entry in IanaToWindowsTzTable:
      if entry.iana == p and entry.windows == w:
        return p
  for entry in IanaToWindowsTzTable:
    if entry.windows == w:
      return entry.iana
  return ""

# ---------------------------------------------------------------------------
# `tzutil /g` output parser.
#
# Windows: `tzutil /g` prints the active Windows timezone name on one
# line, e.g. `FLE Standard Time`. A trailing CR/LF is stripped.
# ---------------------------------------------------------------------------

proc parseTzutilOutput*(rawOutput: string): string =
  ## Parse the single-line output of `tzutil /g`. Empty output means
  ## the command failed or the timezone could not be read; the caller
  ## treats that as absent.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len > 0:
      return t
  return ""

# ---------------------------------------------------------------------------
# Linux `/etc/timezone` reader output normalization.
#
# A `/etc/timezone` file is a single line bearing the IANA name; some
# distros include a trailing newline; some legacy systems include
# `#`-comments — strip them.
# ---------------------------------------------------------------------------

proc parseEtcTimezone*(rawContent: string): string =
  ## Parse the contents of `/etc/timezone`. The first non-blank,
  ## non-`#`-comment line bears the IANA name; empty input means the
  ## file did not exist or could not be read.
  for line in rawContent.splitLines():
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    return stripped
  return ""

proc parseTimedatectlOutput*(rawOutput: string): string =
  ## Parse the `Time zone: <iana> (...)` line out of `timedatectl
  ## status` (or `timedatectl show --property=Timezone`) output. The
  ## `show` form prints `Timezone=<iana>` on a single line; the
  ## `status` form prints `Time zone: <iana> (...)`. Accepts both.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len == 0:
      continue
    if t.toLowerAscii().startsWith("timezone="):
      let v = t[len("timezone=") .. ^1].strip()
      if v.len > 0:
        return v
    elif t.toLowerAscii().startsWith("time zone:"):
      let after = t[len("time zone:") .. ^1].strip()
      # The status form often appends ` (UTC, +0000)`; cut at the
      # first whitespace.
      var iana = ""
      for ch in after:
        if ch == ' ' or ch == '\t':
          break
        iana.add(ch)
      if iana.len > 0:
        return iana
  return ""

proc parseSystemsetupTimezoneOutput*(rawOutput: string): string =
  ## Parse the `Time Zone: <iana>` line of `systemsetup
  ## -gettimezone` (macOS). The macOS form prints exactly that one
  ## line.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.toLowerAscii().startsWith("time zone:"):
      return t[len("time zone:") .. ^1].strip()
  return ""

# ---------------------------------------------------------------------------
# Canonical state / desired digests.
# ---------------------------------------------------------------------------

proc canonicalIanaTimezone*(iana: string): string =
  ## Collapse IANA timezone aliases that resolve to the same offset and
  ## tzdata file onto a single canonical name. Without this, the
  ## drift digest compares `UTC` (the `/etc/localtime` symlink-target
  ## basename on every glibc distro) against `Etc/UTC` (the
  ## profile-declared IANA name on the M7 fixture) byte-for-byte and
  ## reports a spurious `update` action in the read-only plan. The IANA
  ## tzdb itself ships these names as `Link` aliases pointing at the
  ## same file, so collapsing them is semantically correct.
  ##
  ## The Recipe-Validation M7 finding ("Timezone driver — Etc/UTC
  ## fast-path missing", see `tools/multi-distro-harness/README.md`)
  ## traces directly to this normalisation gap: every fresh WSL glibc
  ## distro pre-sets `/etc/localtime -> /usr/share/zoneinfo/UTC` so
  ## `timedatectl show --property=Timezone --value` returns `UTC`,
  ## while the profile fixture declares `Etc/UTC`. The two strings
  ## hash differently without collapsing.
  let t = iana.strip()
  case t
  of "Etc/UTC", "Etc/Zulu", "Zulu", "Universal", "Etc/Universal":
    "UTC"
  of "Etc/GMT", "GMT", "GMT0", "Etc/GMT0", "Etc/Greenwich", "Greenwich",
     "Etc/GMT+0", "Etc/GMT-0":
    # All these names map (via the IANA `backward` aliases) to the
    # zero-offset `Etc/GMT` file. Collapse to a single canonical form;
    # the IANA tzdb itself classes them as the same zone. `Etc/GMT+0`
    # and `Etc/GMT-0` are zero-offset link entries per the IANA `etcetera`
    # zone table; the non-zero `Etc/GMT+N` / `Etc/GMT-N` zones are
    # different offsets and must NOT be collapsed here.
    "Etc/GMT"
  else:
    t

proc canonicalTimezoneState*(iana: string): string =
  ## Render an observed IANA timezone name to a stable canonical
  ## rendering used for the broker's drift digest. An empty observed
  ## value indicates the resource is absent (the platform-specific
  ## probe could not read a value). The IANA-alias collapsing above
  ## ensures `UTC` and `Etc/UTC` (and the `GMT` family) hash identically
  ## so the M7 plan-time observation does not surface a spurious
  ## `update` against a no-op fixture.
  if iana.strip().len == 0:
    return "timezone:absent"
  "timezone:" & canonicalIanaTimezone(iana)

proc canonicalTimezoneDesired*(iana: string): string =
  ## The desired canonical rendering. Always uses the IANA name —
  ## the Windows side maps via the table at apply time, so both
  ## scopes digest identically for the same declared profile. Runs
  ## through `canonicalIanaTimezone` so the desired digest matches the
  ## state digest on alias-equivalent inputs.
  "timezone:" & canonicalIanaTimezone(iana)

# ===========================================================================
# os.hostname — charset guard + canonical state.
#
# RFC 1123 + the PowerShell `Rename-Computer` cmdlet impose a charset
# of letters, digits, and `-`; up to 15 octets for the NetBIOS name
# and 63 for the DNS hostname. Reprobuild restricts to the conservative
# RFC 1123 charset and rejects anything outside it so a hostname field
# cannot smuggle a shell metacharacter past the closed-set validator
# (defence-in-depth layer 1; the driver `quoteShell`s the value as
# layer 2).
# ===========================================================================

proc isSafeHostname*(name: string): bool =
  ## True for a non-empty hostname whose every character is in the
  ## RFC 1123 charset (letters, digits, `-`). A leading or trailing
  ## `-` is rejected (the standard forbids it); spaces and shell
  ## metacharacters are refused so the value cannot smuggle a command
  ## past the closed-set validator.
  let n = name.strip()
  if n.len == 0 or n.len > 63:
    return false
  if n[0] == '-' or n[^1] == '-':
    return false
  for ch in n:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '-'}:
      return false
  return true

proc parseHostnameOutput*(rawOutput: string): string =
  ## Parse the single-line output of the `hostname` command. A
  ## trailing CR/LF is stripped; empty output means the command
  ## failed.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len > 0:
      return t
  return ""

proc canonicalHostnameState*(name: string): string =
  ## Canonical rendering of an observed hostname for the drift digest.
  ## The comparison is case-insensitive — `MYHOST` and `myhost` are
  ## the same hostname on every platform Reprobuild targets — so the
  ## canonical form lowercases the value.
  let t = name.strip().toLowerAscii()
  if t.len == 0:
    return "hostname:absent"
  "hostname:" & t

proc canonicalHostnameDesired*(name: string): string =
  ## The desired canonical rendering. Always lowercases the value so
  ## an apply with `MyHost` matches an observed `myhost`.
  "hostname:" & name.strip().toLowerAscii()

proc hostnameMatchesDesired*(observed, desired: string): bool =
  ## True when the observed hostname matches the desired hostname.
  ## Case-insensitive — the OS reports a single canonical case but
  ## the apply target is what the operator typed; we match either.
  canonicalHostnameState(observed) == canonicalHostnameDesired(desired)
