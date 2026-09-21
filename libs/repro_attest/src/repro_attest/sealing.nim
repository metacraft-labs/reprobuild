## Binding a secret to a launch measurement: the policy a TPM will
## require before it releases one, computed from the image's own bytes.
##
## ## What this is for
##
## A machine that keeps its state on encrypted volumes has to get the
## volume key from somewhere at boot, and the only interesting answer is
## "from a TPM, and only if the machine booted the image it was supposed
## to". The TPM mechanism for that is an object sealed under a policy,
## and the policy this module computes is `TPM2_PolicyPCR` over the
## register a UEFI stub extends with the image's sections.
##
## The whole value of the arrangement is that the policy digest is a
## PURE FUNCTION of the image. Nothing has to boot for it to be known:
##
##   image bytes  ->  measureUkiPcr11  ->  PCR 11  ->  pcrPolicyDigest
##
## which is why a generation can be installed and the volume key
## re-sealed for it BEFORE it has ever run — the running system computes
## what the next one will measure to and seals for that value. Without
## the pure function there is no such thing as an unattended update: the
## key would have to be re-sealed after the new generation was already
## running, and a machine that cannot open its own state has no way to
## get there.
##
## ## The digest, exactly
##
## `TPM2_PolicyPCR` folds the selection and the registers into the
## session's running policy digest:
##
##     policyNew = H(policyOld ‖ TPM_CC_PolicyPCR ‖ pcrs ‖ digestTPM)
##
## `policyOld` is the all-zero digest at the start of a fresh session,
## `pcrs` is the MARSHALLED `TPML_PCR_SELECTION`, and `digestTPM` is the
## digest over the concatenated register values — the same composite a
## quote carries, so `pcrComposite` computes it and this module does not
## grow a second opinion about the order registers are digested in.
##
## Each of those is a place to be quietly wrong: the command code is
## folded in as four big-endian bytes and not as a `TPM2B`, `digestTPM`
## is appended RAW and not length-prefixed, and the selection is the wire
## form including its `sizeofSelect` byte. Every one of those mistakes
## produces a stable, plausible, wrong 32 bytes, and a wrong policy
## digest is not detectably wrong until a real TPM refuses to release a
## real key on a machine that has already rebooted.
##
## ## Why the object's ATTRIBUTES are read here too
##
## A sealed object carries an authorisation policy AND a set of
## attributes that say when the policy is actually required. An object
## that still permits its authorisation VALUE to satisfy it — the
## `userWithAuth` attribute — opens with an empty password and no policy
## session at all. Its policy digest can be perfect and pin exactly the
## right measurement, and the object is still readable on any machine
## that has it. That is not a hypothetical: it is the default for
## `TPM2_Create` when no policy is given, and it is one dropped
## attribute away from a sealed object that is sealed to nothing.
##
## So `policyIsTheOnlyAuthorisation` is part of this module's surface and
## not a caller's afterthought. Checking the policy digest without
## checking the attributes answers "is the lock the right shape" while
## leaving "is the door bolted" unasked.
##
## ## Mocking
##
## None. Everything here is a pure function over bytes a TPM produced or
## will require.

import std/[strutils]

import ./tpm2
import ./measurement

type
  SealingError* = object of CatchableError
    ## Raised for a sealed object this module will not read, and for a
    ## policy it will not compute.

  SealedObjectPublic* = object
    ## The public area of a sealed data object, as `TPM2_Create` writes
    ## it: a `TPM2B_PUBLIC` wrapping a `TPMT_PUBLIC` of type
    ## `TPM_ALG_KEYEDHASH`.
    publicArea*: string
      ## The `TPMT_PUBLIC` bytes EXACTLY as they arrived, without the
      ## outer size. The object's name is a digest of these, so a
      ## re-serialisation would be this code's opinion about what the
      ## TPM meant rather than what it named.
    nameAlg*: TpmAlgId
    objectAttributes*: uint32
    authPolicy*: string
      ## RAW digest bytes. Empty when the object carries no policy,
      ## which is a statement worth being able to make.
    scheme*: TpmAlgId
    unique*: string

const
  TpmCcPolicyPcr* = 0x0000017F'u32
    ## `TPM_CC_PolicyPCR`. Folded into the policy digest as four
    ## big-endian bytes.

  TpmAlgKeyedHash* = TpmAlgId(0x0008'u16)
  # ``TpmAlgNull`` is NOT redeclared here. This module imports the structure
  # codec above, which already exports it with the same value, and exporting
  # a second one made the name ambiguous in every module that imported both --
  # which is three gates that stopped compiling entirely, silently, because
  # nothing builds a gate that does not compile.

  # TPMA_OBJECT, the bits this module has an opinion about.
  AttrFixedTpm* = 0x00000002'u32
  AttrFixedParent* = 0x00000010'u32
  AttrSensitiveDataOrigin* = 0x00000020'u32
  AttrUserWithAuth* = 0x00000040'u32
  AttrAdminWithPolicy* = 0x00000080'u32
  AttrNoDa* = 0x00000400'u32

  LaunchPcrSelection* = "sha256:11"
    ## The selection a launch-bound policy is over, in the spelling the
    ## TPM 2.0 command-line tools use, so a diagnostic and an operator's
    ## command line say the same thing.

proc pcrPolicyDigest*(policyAlg: TpmAlgId; sel: TpmlPcrSelection;
                      values: openArray[SelectedPcr]): string =
  ## The policy digest a session holds after one `TPM2_PolicyPCR` over
  ## `sel` with those register values, starting from a fresh session.
  ##
  ## Returns RAW digest bytes, to compare against a sealed object's
  ## `authPolicy` directly.
  ##
  ## `policyAlg` is the session's hash, which for an object created by
  ## these tools is the object's own `nameAlg`. The register values are
  ## checked against the selection by `pcrComposite`, so a value for a
  ## register the selection does not name, or a missing one, is a refusal
  ## there rather than a silently different answer here.
  let size = digestSize(policyAlg)
  if size == 0:
    raise newException(SealingError,
      "policy digest: " & $policyAlg & " is not a digest this build " &
      "computes, so the policy a session would hold under it cannot be " &
      "predicted")
  let composite = pcrComposite(policyAlg, sel, values)
  var preimage = newString(size)
  for i in 0 ..< size: preimage[i] = '\0'
  # The command code, four big-endian bytes. NOT a TPM2B: a length
  # prefix here yields a stable, plausible, wrong digest.
  for shift in [24, 16, 8, 0]:
    preimage.add char(uint8((TpmCcPolicyPcr shr shift) and 0xFF'u32))
  preimage.add serializePcrSelection(sel)
  # The composite is appended RAW, not length-prefixed.
  preimage.add composite
  tpmDigest(policyAlg, preimage)

proc launchPolicyDigest*(pcr11Hex: string): string =
  ## The policy digest for the one selection this product seals under:
  ## SHA-256 register 11, the register a stub extends with the image's
  ## own sections.
  ##
  ## `pcr11Hex` is 64 lower- or upper-case hex characters — the value
  ## `measureUkiPcr11` computes, or the value a machine reports.
  if pcr11Hex.len != PcrDigestSize * 2:
    raise newException(SealingError,
      "policy digest: a sha256 register value is " & $(PcrDigestSize * 2) &
      " hex characters, got " & $pcr11Hex.len &
      "; a truncated register value would seal to a policy no machine " &
      "can satisfy")
  var raw = newString(PcrDigestSize)
  for i in 0 ..< PcrDigestSize:
    try:
      raw[i] = char(parseHexInt(pcr11Hex[2 * i .. 2 * i + 1]))
    except ValueError:
      raise newException(SealingError,
        "policy digest: \"" & pcr11Hex[2 * i .. 2 * i + 1] &
        "\" at character " & $(2 * i) & " is not hexadecimal")
  let sel = pcrSelection(TpmAlgSha256, [Pcr11])
  pcrPolicyDigest(TpmAlgSha256, sel, [selectedPcr(TpmAlgSha256, Pcr11, raw)])

proc launchPolicyDigestForImage*(image: string): string =
  ## The policy digest a unified kernel image will require, computed from
  ## the image's own bytes. This is the whole arrangement in one line: no
  ## machine has to boot for the answer to be known.
  launchPolicyDigest(measureUkiPcr11(image).pcr11)

proc parseSealedObjectPublic*(blob: string): SealedObjectPublic =
  ## Read a `TPM2B_PUBLIC` holding a sealed data object.
  ##
  ## Only `TPM_ALG_KEYEDHASH` with a null scheme is accepted — that is
  ## what a sealed blob is, and a key of some other type read as one
  ## would have its policy field taken from the wrong offset and compare
  ## equal to nothing.
  var r = initTpm2Reader(blob, "TPM2B_PUBLIC")
  let size = int(r.readU16("size"))
  if size == 0:
    raise newException(SealingError,
      "TPM2B_PUBLIC: declares a zero-length public area; an object with " &
      "no public area names nothing and its policy cannot be read")
  if size > r.remaining:
    raise newException(SealingError,
      "TPM2B_PUBLIC: declares " & $size & " bytes of public area but " &
      $r.remaining & " remain")
  result.publicArea = r.readBytes("publicArea", size)
  if r.remaining != 0:
    raise newException(SealingError,
      "TPM2B_PUBLIC: " & $r.remaining & " bytes follow the public area; " &
      "a sealed object's public blob is exactly one structure and " &
      "trailing bytes mean this is not the file it was taken for")

  var p = initTpm2Reader(result.publicArea, "TPMT_PUBLIC")
  let objType = p.readAlg("type")
  if objType != TpmAlgKeyedHash:
    raise newException(SealingError,
      "TPMT_PUBLIC: type is " & $objType & ", not " & $TpmAlgKeyedHash &
      "; a sealed data object is a keyed-hash object, and reading any " &
      "other type as one takes every field that follows from the wrong " &
      "offset")
  result.nameAlg = p.readAlg("nameAlg")
  if digestSize(result.nameAlg) == 0:
    raise newException(SealingError,
      "TPMT_PUBLIC: nameAlg is " & $result.nameAlg &
      ", whose digest length this build does not know, so neither the " &
      "object's name nor its policy digest can be computed")
  result.objectAttributes = p.readU32("objectAttributes")
  result.authPolicy = p.readTpm2b("authPolicy", 64)
  result.scheme = p.readAlg("parameters.keyedHashDetail.scheme")
  if result.scheme != TpmAlgNull:
    raise newException(SealingError,
      "TPMT_PUBLIC: the keyed-hash scheme is " & $result.scheme &
      ", not null; this object is a signing or derivation key rather " &
      "than sealed data, and its sensitive area is not a secret to " &
      "release")
  result.unique = p.readTpm2b("unique", 64)
  p.finish()

proc sealedObjectName*(obj: SealedObjectPublic): string =
  ## The object's `TPM2B_NAME` content: the name algorithm followed by
  ## the digest of the public area, RAW.
  ##
  ## This is what makes a pinned public blob checkable against a second
  ## artifact. The name is what the TPM itself computed and wrote out at
  ## load time; the public area is what it was computed FROM. A typo in
  ## either is caught by the other, which is the only protection a
  ## recorded byte string has.
  result = newString(2)
  result[0] = char(uint8((uint16(obj.nameAlg) shr 8) and 0xFF'u16))
  result[1] = char(uint8(uint16(obj.nameAlg) and 0xFF'u16))
  result.add tpmDigest(obj.nameAlg, obj.publicArea)

proc policyIsTheOnlyAuthorisation*(obj: SealedObjectPublic): bool =
  ## Whether satisfying the policy is the ONLY way this object opens.
  ##
  ## Three conditions, and all three are load-bearing:
  ##
  ##   * it carries a policy at all — an empty `authPolicy` is a policy
  ##     no session can be checked against, so the TPM does not check
  ##     one;
  ##   * `userWithAuth` is CLEAR — with it set the authorisation VALUE
  ##     satisfies user-role commands, and `TPM2_Unseal` is a user-role
  ##     command, so the object opens with an empty password and no
  ##     session;
  ##   * `adminWithPolicy` is SET — which is what the TPM requires of an
  ##     object whose administrative role is policy-only, and what
  ##     `TPM2_Create` refuses to omit once `userWithAuth` is cleared.
  ##
  ## The second is the one that matters and the one that is invisible in
  ## a policy digest: an object with a perfect policy and `userWithAuth`
  ## set is sealed to nothing at all.
  obj.authPolicy.len > 0 and
    (obj.objectAttributes and AttrUserWithAuth) == 0'u32 and
    (obj.objectAttributes and AttrAdminWithPolicy) != 0'u32

proc explainSealedObject*(obj: SealedObjectPublic): string =
  ## A one-line rendering for a diagnostic: what the object requires, and
  ## what it does not.
  var attrs: seq[string] = @[]
  if (obj.objectAttributes and AttrFixedTpm) != 0'u32: attrs.add "fixedtpm"
  if (obj.objectAttributes and AttrFixedParent) != 0'u32: attrs.add "fixedparent"
  if (obj.objectAttributes and AttrSensitiveDataOrigin) != 0'u32:
    attrs.add "sensitivedataorigin"
  if (obj.objectAttributes and AttrUserWithAuth) != 0'u32: attrs.add "userwithauth"
  if (obj.objectAttributes and AttrAdminWithPolicy) != 0'u32:
    attrs.add "adminwithpolicy"
  if (obj.objectAttributes and AttrNoDa) != 0'u32: attrs.add "noda"
  result = "sealed object nameAlg=" & $obj.nameAlg &
    " attributes=" & attrs.join("|") &
    " authPolicy=" & (if obj.authPolicy.len == 0: "none"
                      else: $obj.authPolicy.len & " bytes")
  if not policyIsTheOnlyAuthorisation(obj):
    result.add " — THE POLICY IS NOT THE ONLY WAY IN"
