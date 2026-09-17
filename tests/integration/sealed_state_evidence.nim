## Reading one power cycle's account of itself, and asking it the two
## questions that must not collapse into one.
##
## The harness that took this evidence writes a flat `key=value` record
## per cycle. This file turns one into a record, and defines the two
## predicates the sealing gates rest on:
##
##   * `sealedObjectRefused` — did the TPM decline to release the secret?
##   * `stateVolumesLocked`  — are the encrypted volumes still shut?
##
## **They are separate functions over disjoint fields on purpose, and
## that is the whole substance of the third gate.** A verifier that
## refuses while the disk quietly unlocks is worse than no verifier at
## all, so "it refused" must never be able to stand in for "it stayed
## locked". The two predicates read no field in common: the first reads
## only `unseal_*`, the second reads only `mapper_entries`, `status_*`
## and `marker_*`.
##
## Disjointness is not argued from the source text — a reader that
## claimed it and did not have it would look identical. It is
## established by INPUT: the pinned evidence contains a real boot in
## which the first predicate is TRUE and the second is FALSE, and
## another in which the first is FALSE and the second is FALSE. So
## neither is a function of the other, and neither is constant.
##
## ## Every field is REQUIRED
##
## `field` raises on a key the record does not carry rather than
## returning an empty string. A predicate that silently read "" for a
## missing `status_var` would answer "locked" about a record that never
## said anything of the kind, which is the honest-absence failure in its
## purest form: the gate would be greenest exactly when the evidence was
## emptiest.
##
## ## Mocking
##
## None.

import std/[strutils, tables]

include ./sealed_state_vectors

type
  CycleEvidenceError* = object of CatchableError

  CycleReport* = object
    ## One power cycle's record, as the guest wrote it.
    phase*: string
    fields*: Table[string, string]

  VolumeName* = enum
    vnVar = "var"
    vnHome = "home"

const
  StateVolumes* = [vnVar, vnHome]
    ## The state volumes this machine carries. Both are checked
    ## separately everywhere: a gate that looked at one would pass a
    ## machine that left the other open.

  PolicyFailureCode* = "0x99D"
    ## `TPM_RC_POLICY_FAIL` as the TPM 2.0 command tools render it. The
    ## refusal a measurement mismatch produces, and the ONLY refusal this
    ## evidence is allowed to call a measurement mismatch — an unseal
    ## that failed because the object would not load, or because the
    ## session was never started, is a broken experiment rather than a
    ## caught tamper, and it would carry a different code or none.

  AuthUnavailableCode* = "0x12F"
    ## `TPM_RC_AUTH_UNAVAILABLE`. What the TPM answers when a sealed
    ## object is asked to open with its authorisation VALUE and its
    ## attributes say only a policy will do. Pinned because the
    ## alternative — an object that opens this way — is a sealed object
    ## that is sealed to nothing, and no policy digest would reveal it.

  LuksSignatureHex* = "4c554b53babe"
    ## `LUKS\xba\xbe`, the LUKS2 header signature. Read off the raw block
    ## device with no mapping in the way, so "this is a real encrypted
    ## volume" is a statement about the disk rather than about a name in
    ## `/dev/mapper`.

proc unhexBytes*(h: string): string =
  ## Hex to raw bytes. The pinned evidence is hex because a Nim source
  ## file is text; everything this tree computes over it is bytes.
  if h.len mod 2 != 0:
    raise newException(CycleEvidenceError,
      "a hex string has an even number of characters, this one has " & $h.len)
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

proc hexOf*(b: string): string =
  ## Raw bytes to lower-case hex, the spelling every pinned constant
  ## here uses.
  for c in b: result.add toHex(int(uint8(c)), 2).toLowerAscii

proc parseCycleReport*(text: string): CycleReport =
  ## Parse one cycle's record. A line without an `=` is a refusal: the
  ## records are machine-written, so a malformed one means the guest died
  ## mid-write and every conclusion drawn from it would be about a
  ## truncated boot.
  result.fields = initTable[string, string]()
  var lines = 0
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(CycleEvidenceError,
        "cycle report: line " & $(lines + 1) & " is \"" & line &
        "\", which carries no key; the records are machine-written, so a " &
        "line like this means the guest stopped part way through writing " &
        "one")
    result.fields[line[0 ..< eq]] = line[eq + 1 .. ^1]
    inc lines
  if "phase" notin result.fields:
    raise newException(CycleEvidenceError,
      "cycle report: no `phase` line, so this record does not say which " &
      "power cycle it is an account of")
  if "end" notin result.fields:
    raise newException(CycleEvidenceError,
      "cycle report: no `end` line. The guest writes it last, so its " &
      "absence means the record is a PREFIX of a cycle and the fields " &
      "that are present say nothing about the ones that are not")
  result.phase = result.fields["phase"]

proc field*(r: CycleReport; key: string): string =
  ## One field, or a refusal. Never an empty default: see the header.
  if key notin r.fields:
    raise newException(CycleEvidenceError,
      "cycle report " & r.phase & ": no field `" & key &
      "`; this record cannot answer a question about it, and answering " &
      "as though it had said nothing would make an empty record the " &
      "most reassuring one")
  r.fields[key]

proc intField*(r: CycleReport; key: string): int =
  let raw = r.field(key)
  try:
    parseInt(raw)
  except ValueError:
    raise newException(CycleEvidenceError,
      "cycle report " & r.phase & ": field `" & key & "` is \"" & raw &
      "\", which is not a number")

proc pcr11*(r: CycleReport): string =
  ## The register the guest read out of its own sysfs, lower-cased. The
  ## kernel renders it upper-case; every other register value in this
  ## tree is lower-case hex.
  r.field("pcr11").toLowerAscii

# ---------------------------------------------------------------------
# Question one: did the TPM refuse?
#
# Reads ONLY the unseal fields. It knows nothing about volumes.
# ---------------------------------------------------------------------

proc sealedObjectRefused*(r: CycleReport; slot: string): bool =
  ## Whether the TPM declined to release slot `slot`'s secret BECAUSE
  ## THE POLICY WAS NOT MET.
  ##
  ## Both halves are required. A non-zero status alone would be
  ## satisfied by a command that never reached the TPM — a missing file,
  ## a session that failed to start — and that is a broken experiment
  ## wearing a caught tamper's clothes.
  r.intField("unseal_" & slot & "_rc") != 0 and
    r.field("unseal_" & slot & "_tpm_rc") == PolicyFailureCode

proc sealedObjectReleased*(r: CycleReport; slot: string): bool =
  ## Whether the TPM released it. Not the negation of the above: a
  ## refusal for some OTHER reason is neither, and a gate that wrote
  ## `not refused` would call such a cycle a success.
  r.intField("unseal_" & slot & "_rc") == 0 and
    r.field("unseal_" & slot & "_tpm_rc").len == 0

proc authValueWasRefused*(r: CycleReport; slot: string): bool =
  ## Whether the no-session probe was refused with
  ## `TPM_RC_AUTH_UNAVAILABLE`.
  ##
  ## This is the OTHER way a sealed object can be open in practice while
  ## looking sealed on paper, and it is invisible in a policy digest: an
  ## object whose `userWithAuth` attribute is set opens with an empty
  ## password and no policy session at all.
  r.intField("unseal_" & slot & "_noauth_rc") != 0 and
    r.field("unseal_" & slot & "_noauth_tpm_rc") == AuthUnavailableCode

# ---------------------------------------------------------------------
# Question two: are the volumes still locked?
#
# Reads ONLY the volume fields. It knows nothing about the TPM.
# ---------------------------------------------------------------------

proc stateVolumesLocked*(r: CycleReport): bool =
  ## Whether BOTH state volumes are shut.
  ##
  ## Three independent readings have to agree, because each alone has a
  ## way of being true about a machine whose disk is open:
  ##
  ##   * no device-mapper entry exists;
  ##   * `cryptsetup status` reports each volume inactive;
  ##   * the plaintext marker is unreadable.
  ##
  ## The last is the one that is about the DATA rather than about the
  ## bookkeeping. A machine could in principle have torn its mapping down
  ## after reading the plaintext, and the first two would then describe a
  ## locked volume on a machine that had already seen inside it.
  if r.field("mapper_entries").len != 0: return false
  for v in StateVolumes:
    if r.field("status_" & $v) != "inactive": return false
    if r.field("marker_" & $v) != "-": return false
  true

proc stateVolumesOpen*(r: CycleReport): bool =
  ## Whether BOTH state volumes are open AND their plaintext is readable.
  ## Again not a negation: a cycle in which one opened and one did not is
  ## neither, and must not be read as either.
  if r.field("mapper_entries").len == 0: return false
  for v in StateVolumes:
    if r.field("status_" & $v) != "active": return false
    if r.field("marker_" & $v).len != 64: return false
  true

proc marker*(r: CycleReport; v: VolumeName): string =
  r.field("marker_" & $v)

proc ciphertextAt*(r: CycleReport; v: VolumeName): string =
  ## What the raw block device carries where the marker sits — i.e. at
  ## the LUKS data offset, with no mapping in the way.
  r.field("raw_data_" & $v)

proc carriesLuksSignature*(r: CycleReport; v: VolumeName): bool =
  r.field("raw_magic_" & $v) == LuksSignatureHex

proc volumeIdentity*(r: CycleReport; v: VolumeName): string =
  ## The LUKS header UUID, which is readable without any key. It is how
  ## a later cycle can say it is looking at the SAME volume rather than
  ## at a freshly formatted one that happens to answer the same way.
  r.field("luks_uuid_" & $v)
