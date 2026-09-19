## Reading one remote-unseal experiment's records, and asking them the
## three questions that must not collapse into one.
##
## The harness that took this evidence writes flat `key=value` records,
## and it writes them from THREE DIFFERENT PRODUCERS:
##
##   * the **client**, inside the guest, which says what the broker
##     answered and whether it ran the volume opener;
##   * the **guest's init**, which says what the block devices look like
##     afterwards;
##   * the **host**, which searched the console logs and the images with
##     no guest involved.
##
## The three predicates this file defines are over three different
## documents:
##
##   * `brokerRefused`            — the client's record, `unseal_*` and
##                                  `broker_status` only.
##   * `stateVolumesLocked`       — the guest's record, `mapper_entries`,
##                                  `status_*` and `marker_*` only.
##   * `bootReachedEncryptedRoot` — the host's search record, the
##                                  sentinel and handoff counts only.
##
## **That separation is the whole substance of the refusal gate.** A
## client that says "no" and a disk that opens anyway is worse than no
## client at all: it has the appearance of enforcement and none of the
## substance, and every operator who reads the refusal will believe the
## data was protected. So "it refused" must never be able to stand in for
## "it stayed locked", and neither may stand in for "the machine did not
## come up".
##
## Disjointness is not argued from the source text — a reader that
## claimed it and did not have it would look identical. It is established
## by INPUT. The pinned evidence contains a real boot in which the first
## predicate is TRUE and the other two say the machine came up with its
## disk open, and another in which the first is FALSE and the machine
## came up the same way. No predicate is a function of another and none
## is constant.
##
## ## Every field is REQUIRED
##
## `field` raises on a key the record does not carry rather than
## returning an empty string. A predicate that silently read "" for a
## missing `status_root` would answer "locked" about a record that never
## said anything of the kind, which is the honest-absence failure in its
## purest form: the gate would be greenest exactly when the evidence was
## emptiest.
##
## ## Mocking
##
## None.

import std/[strutils, tables]

include ./remote_unseal_vectors

type
  UnsealEvidenceError* = object of CatchableError

  UnsealRecord* = object
    ## One flat record, as whichever producer wrote it.
    fields*: Table[string, string]

  UnsealVolume* = enum
    uvRoot = "root"
    uvHome = "home"

const
  StateVolumes* = [uvRoot, uvHome]
    ## Both are checked separately everywhere: a gate that looked at one
    ## would pass a machine that left the other open.

  LuksSignatureHex* = "4c554b53babe"
    ## `LUKS\xba\xbe`, the LUKS2 header signature, read off the raw block
    ## device with no mapping in the way — so "this is a real encrypted
    ## volume" is a statement about the disk rather than about a name in
    ## `/dev/mapper`.

  ReleaseStatusRefusal* = "release-status"
    ## The one refusal value this evidence is allowed to call a broker
    ## refusal. A client that gave up because it could not reach the
    ## broker, or because its own machine could not produce evidence, has
    ## produced a broken experiment rather than a decision anybody made,
    ## and it carries a different value.

  NoRefusal* = "-"
    ## What the client writes in `unseal_refusal` when it recovered a key.

  BrokerRefusedStatus* = 403
    ## What the broker answers when it decides not to release. Pinned by
    ## value: a 5xx would mean the broker fell over, which is not a
    ## decision, and a client that treated the two alike would retry one
    ## of them.

  BrokerReleasedStatus* = 200

proc parseUnsealRecord*(text: string): UnsealRecord =
  ## Parse one record. A line without an `=` is a refusal: the records
  ## are machine-written, so a malformed one means the producer died
  ## mid-write and every conclusion drawn from it would be about a
  ## truncated run.
  result.fields = initTable[string, string]()
  var lines = 0
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0:
      raise newException(UnsealEvidenceError,
        "unseal record: line " & $(lines + 1) & " is \"" & line &
        "\", which carries no key; the records are machine-written, so a " &
        "line like this means the producer stopped part way through " &
        "writing one")
    result.fields[line[0 ..< eq]] = line[eq + 1 .. ^1]
    inc lines
  if "end" notin result.fields:
    raise newException(UnsealEvidenceError,
      "unseal record: no `end` line. Every producer writes it last, so " &
      "its absence means the record is a PREFIX of a run and the fields " &
      "that are present say nothing about the ones that are not")

proc parseCycleRecord*(text: string): UnsealRecord =
  ## A record that must also say which power cycle it is an account of.
  result = parseUnsealRecord(text)
  if "cycle" notin result.fields:
    raise newException(UnsealEvidenceError,
      "unseal record: no `cycle` line, so this record does not say which " &
      "power cycle it is an account of")

proc field*(r: UnsealRecord; key: string): string =
  ## One field, or a refusal. Never an empty default: see the header.
  if key notin r.fields:
    raise newException(UnsealEvidenceError,
      "unseal record: no field `" & key &
      "`; this record cannot answer a question about it, and answering " &
      "as though it had said nothing would make an empty record the most " &
      "reassuring one")
  r.fields[key]

proc intField*(r: UnsealRecord; key: string): int =
  let raw = r.field(key)
  try:
    parseInt(raw)
  except ValueError:
    raise newException(UnsealEvidenceError,
      "unseal record: field `" & key & "` is \"" & raw &
      "\", which is not a number")

proc cycle*(r: UnsealRecord): string = r.field("cycle")

# ---------------------------------------------------------------------
# Question one: what did the broker answer?
#
# Reads ONLY the client's record, and only its `broker_status` and
# `unseal_*` fields. It knows nothing about volumes and nothing about
# whether the machine came up.
# ---------------------------------------------------------------------

proc brokerRefused*(client: UnsealRecord): bool =
  ## Whether the broker answered and declined.
  ##
  ## All three halves are required. "The client came back without a key"
  ## alone would be satisfied by a client that never reached the broker
  ## — a broken experiment wearing a refusal's clothes — and a status
  ## alone would be satisfied by a broker that fell over.
  client.field("unseal_decision") == "refused" and
    client.field("unseal_refusal") == ReleaseStatusRefusal and
    client.intField("broker_status") == BrokerRefusedStatus

proc brokerReleased*(client: UnsealRecord): bool =
  ## Whether the broker released a key. Not the negation of the above: a
  ## client that failed for some OTHER reason is neither, and a gate that
  ## wrote `not brokerRefused` would call such a boot a success.
  client.field("unseal_decision") == "unsealed" and
    client.field("unseal_refusal") == NoRefusal and
    client.intField("broker_status") == BrokerReleasedStatus

proc openerWasExecuted*(client: UnsealRecord): bool =
  ## Whether the client ran the program that opens volumes AT ALL.
  ##
  ## This is the client's own account of the thing the type system is
  ## supposed to make impossible on a refusal, and it is deliberately a
  ## separate question from what the broker said: a client that refused
  ## and then opened the volumes anyway would answer TRUE here and TRUE
  ## to `brokerRefused`, and that combination is the defect.
  client.intField("opener_ran") != 0

proc volumesOpenedByClient*(client: UnsealRecord): int =
  client.intField("volumes_opened")

# ---------------------------------------------------------------------
# Question two: are the volumes still locked?
#
# Reads ONLY the guest's record, and only its volume fields. It knows
# nothing about the broker.
# ---------------------------------------------------------------------

proc stateVolumesLocked*(guest: UnsealRecord): bool =
  ## Whether BOTH state volumes are shut.
  ##
  ## Three independent readings have to agree, because each alone has a
  ## way of being true about a machine whose disk is open:
  ##
  ##   * no device-mapper entry exists;
  ##   * `cryptsetup status` reports each volume inactive;
  ##   * the plaintext marker inside each volume is unreadable.
  ##
  ## The last is the one about the DATA rather than about the
  ## bookkeeping. A machine could in principle have torn its mapping down
  ## after reading the plaintext, and the first two would then describe a
  ## locked volume on a machine that had already seen inside it.
  if guest.field("mapper_entries").len != 0: return false
  for v in StateVolumes:
    if guest.field("status_" & $v) != "inactive": return false
    if guest.field("marker_" & $v) != "-": return false
  true

proc stateVolumesOpen*(guest: UnsealRecord): bool =
  ## Whether BOTH volumes are open AND their plaintext is readable.
  ## Again not a negation: a cycle in which one opened and one did not is
  ## neither, and must not be read as either.
  if guest.field("mapper_entries").len == 0: return false
  for v in StateVolumes:
    if guest.field("status_" & $v) != "active": return false
    if guest.field("marker_" & $v).len != 64: return false
  true

proc marker*(guest: UnsealRecord; v: UnsealVolume): string =
  guest.field("marker_" & $v)

proc volumeIdentity*(guest: UnsealRecord; v: UnsealVolume): string =
  ## The LUKS header UUID, which is readable without any key. It is how a
  ## later cycle can say it is looking at the SAME volume rather than at
  ## a freshly formatted one that happens to answer the same way.
  guest.field("luks_uuid_" & $v)

proc ciphertextAt*(guest: UnsealRecord; v: UnsealVolume): string =
  ## What the raw block device carries at the LUKS data offset, with no
  ## mapping in the way.
  guest.field("raw_data_" & $v)

proc carriesLuksSignature*(guest: UnsealRecord; v: UnsealVolume): bool =
  guest.field("raw_magic_" & $v) == LuksSignatureHex

proc probeReachedTheKeySlots*(guest: UnsealRecord): bool =
  ## Whether an unlock attempt was really made and really turned away.
  ##
  ## Without this, "the volumes stayed locked" on a refused boot would be
  ## a statement about control flow in the guest's init rather than about
  ## the volumes: nothing would have asked them to open. The probe is the
  ## thing that asks, with a key that is WRONG rather than absent.
  guest.intField("probe_ran") == 1 and
    guest.intField("probe_root_rc") != 0 and
    guest.intField("probe_home_rc") != 0

proc probeOpenedTheVolumes*(guest: UnsealRecord): bool =
  ## The other direction, which only the locally-keyed control produces.
  guest.intField("probe_ran") == 1 and
    guest.intField("probe_root_rc") == 0 and
    guest.intField("probe_home_rc") == 0

proc machineHasNoLocalRootOfTrust*(guest: UnsealRecord): bool =
  ## No TPM device, no TPM class entry. Read off the machine rather than
  ## asserted about it, because "there is no local sealing here" is the
  ## premise of the whole experiment and a premise nobody measured is a
  ## premise.
  guest.intField("tpm_devices") == 0 and
    guest.intField("tpm_class_entries") == 0

proc machineCarriesALocalKey*(guest: UnsealRecord): bool =
  ## Whether this machine has a cached copy of its own volume key. TRUE
  ## on the control and FALSE on every honest boot, and it is the ONE
  ## thing that differs between them.
  guest.intField("local_key_files") != 0

# ---------------------------------------------------------------------
# Question three: did the machine come up?
#
# Reads ONLY the host's search record. It knows nothing about the broker
# and nothing about `/dev/mapper`.
# ---------------------------------------------------------------------

proc bootReachedEncryptedRoot*(search: UnsealRecord; cycle: string): bool =
  ## Whether the root filesystem INSIDE the encrypted volume executed.
  ##
  ## Three readings again, and the first is the one that cannot be
  ## produced any other way: the sentinel is written into that filesystem
  ## at enrolment and exists nowhere else afterwards — not in the
  ## initramfs, not in the kernel, not in the shared directory — so a
  ## sentinel on the console is a statement that bytes from inside
  ## ciphertext ran.
  search.intField("console_sentinel_" & cycle) > 0 and
    search.intField("rootfs_report_" & cycle) == 1 and
    search.intField("handoff_" & cycle) > 0

proc searchFindsToken*(search: UnsealRecord; key: string): int =
  search.intField(key)

proc coverage*(search: UnsealRecord; key: string): tuple[found, planted: int] =
  ## `<found>/<planted>` — how many of the planted copies of a token the
  ## same search found. A negative result from a search that has not been
  ## shown to find anything is worth nothing, and a token planted only at
  ## the easiest place is not a coverage measurement.
  let raw = search.field(key)
  let slash = raw.find('/')
  if slash <= 0:
    raise newException(UnsealEvidenceError,
      "coverage field `" & key & "` is \"" & raw &
      "\", which is not <found>/<planted>")
  try:
    (parseInt(raw[0 ..< slash]), parseInt(raw[slash + 1 .. ^1]))
  except ValueError:
    raise newException(UnsealEvidenceError,
      "coverage field `" & key & "` is \"" & raw & "\", whose halves are " &
      "not numbers")
