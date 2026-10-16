## Commitments to the private halves of an inference: the prompt, the
## source it was about, and the output.
##
## ## The problem this exists for
##
## A statement about an inference has to bind *what was asked* and *what
## came back*, or it is a statement about nothing. It must also be
## verifiable by someone who is not allowed to read either. Those two
## requirements are only compatible through a commitment: the statement
## carries a short value that the plaintext opens and nothing else does,
## the verifier checks the binding over that value, and the plaintext
## never leaves the party that holds it.
##
## ## The construction
##
## ::
##
##   commitment = "sha256:" ‖ hex( SHA-256(
##       "ReproOS-INF-COMMIT-v1"
##     ‖ be32(len domain)    ‖ domain
##     ‖ be32(len salt)      ‖ salt
##     ‖ be32(len plaintext) ‖ plaintext ) )
##
## ``salt`` is exactly ``CommitmentSaltBytes`` raw bytes drawn from the
## operating system's random source. ``plaintext`` is raw bytes — a
## prompt, a source tree's canonical bytes, a completion — and is never
## interpreted here.
##
## ## Why a bare hash is not enough, stated rather than implied
##
## A commitment that is only ``SHA-256(plaintext)`` is **binding but not
## hiding**, and for the inputs this module exists to protect that is not
## a technicality. A prompt is frequently short, frequently drawn from a
## small set a reader can guess ("summarise this file", a yes/no
## question, a template with one variable), and a hash of it can be
## confirmed by anyone who guesses it. That is a total break of the only
## property the commitment was carried for.
##
## The salt is therefore mandatory and fixed-length, not optional and not
## caller-chosen-length: a scheme whose hiding depends on how long a
## caller decided the salt should be has no floor at all.
##
## **What this construction is worth, exactly.** Hiding rests on SHA-256
## behaving as a random oracle over an unpredictable 32-byte salt, and it
## is *computational*: a party who learns the salt learns how to confirm a
## guess. It is not the information-theoretic hiding a Pedersen
## commitment gives, and this build carries no group to build one in. A
## reader deciding whether this is enough should read that sentence and
## not the word "commitment".
##
## ## Why the domain is inside the hash
##
## A commitment to a request and a commitment to a response are carried
## side by side in one statement. Without a domain they are values of the
## same type over the same plaintext space, so an opening of one is an
## opening of the other and a statement's two halves could be swapped by
## anyone able to reorder two fields. The domain is a closed enum: a new
## use is a new member, never a reinterpretation of an old one.
##
## ## Why every part is length-prefixed
##
## The same reason ``binding``'s report-data construction is. An unframed
## concatenation of variable-length parts is ambiguous: with no framing,
## ``(salt = S, plaintext = P)`` and ``(salt = S ‖ P1, plaintext = P2)``
## where ``P = P1 ‖ P2`` produce the *same* commitment. One of those two
## parts is chosen by the committer and the other is the secret, so the
## committer picks the boundary — which is exactly the party a commitment
## is supposed to be binding on.
##
## ## What is NOT here
##
## No opening ever reaches a verifier. ``openCommitment`` is on this side
## of the library, for the party that holds the plaintext and wants to
## prove something about it to an auditor who has been granted it. The
## verifier's entry point in ``repro_attest_verify/inference`` takes no
## plaintext parameter and there is no overload of it that does.
##
## ## Mocking
##
## None. Real SHA-256, real operating-system randomness.

import std/sysrand

import ./binding
import ./manifest
import ./measurement

type
  CommitmentDomain* = enum
    ## What a commitment is a commitment *to*. Inside the hash, so an
    ## opening of one domain is not an opening of another.
    cdRequest = "request"
      ## Everything the caller supplied: the prompt, the system prompt,
      ## the tool definitions, the source under discussion.
    cdResponse = "response"
      ## Everything that came back: the completion, the tool calls, the
      ## stop reason.

  CommitmentError* = object of CatchableError
    ## Raised for a commitment this module will not produce or honour.
    ## Its reader is whoever has to fix a request.

const
  CommitmentDomainTag* = "ReproOS-INF-COMMIT-v1"
    ## Versioned, and first. A future construction is a new tag, never a
    ## new reading of this one.

  CommitmentSaltBytes* = 32
    ## Exactly 32, not "at least 32". A caller cannot choose a shorter
    ## one and there is no argument by which it could: the salt is the
    ## whole of the hiding property, and a floor that a caller may sit on
    ## is not a floor.

  MaxCommitmentPlaintextBytes* = 16 * 1024 * 1024
    ## A guard, not a policy. Sixteen megabytes is far past any prompt
    ## and past most sources; a caller committing to more than that
    ## should say what it is doing.

proc newCommitmentSalt*(): string =
  ## ``CommitmentSaltBytes`` raw bytes from the operating system.
  ##
  ## Refuses rather than degrades, for the reason ``challenge``'s nonce
  ## minting does: a salt nobody can predict and a salt somebody can are
  ## the same length, and only one of them hides anything.
  var buf = newSeq[byte](CommitmentSaltBytes)
  if not urandom(buf):
    raise newException(CommitmentError,
      "the operating system's random source would not produce " &
      $CommitmentSaltBytes & " bytes; refusing to mint a commitment salt " &
      "from anything else, because the salt is the whole of this " &
      "construction's hiding property")
  result = newString(CommitmentSaltBytes)
  for i, b in buf: result[i] = char(b)

proc validateCommitmentSalt*(where, salt: string) =
  ## Both directions. A salt that is too long is refused as well as one
  ## that is too short: a variable-length salt is a second way to spell
  ## the same commitment, and one spelling is the point.
  if salt.len != CommitmentSaltBytes:
    raise newException(CommitmentError,
      where & " is " & $salt.len & " bytes; a commitment salt is exactly " &
      $CommitmentSaltBytes & " bytes, because a salt a caller may shorten " &
      "is a hiding property a caller may switch off")

proc commitmentPreimage*(domain: CommitmentDomain;
                         salt, plaintext: string): string =
  ## The exact bytes that are hashed, raw in and raw out.
  ##
  ## Exposed for the reason ``bindingPreimage`` is: a second
  ## implementation can be checked against the *framing* rather than only
  ## against the digest, so a wrong framing that agrees on one vector is
  ## visible instead of merely improbable.
  ##
  ## This is the construction and carries no policy — it will frame a
  ## salt of any length, including lengths ``commitTo`` refuses.
  result = CommitmentDomainTag
  let d = $domain
  result.add be32Prefix(d.len)
  result.add d
  result.add be32Prefix(salt.len)
  result.add salt
  result.add be32Prefix(plaintext.len)
  result.add plaintext

proc commitTo*(domain: CommitmentDomain; salt, plaintext: string): string =
  ## ``sha256:<hex>`` — the one spelling every digest in this chain uses,
  ## so a commitment, a manifest digest and a pinned measurement are
  ## named the same way and no reader has to learn a second convention.
  validateCommitmentSalt("the commitment salt", salt)
  if plaintext.len > MaxCommitmentPlaintextBytes:
    raise newException(CommitmentError,
      "the committed plaintext is " & $plaintext.len & " bytes and at most " &
      $MaxCommitmentPlaintextBytes & " are committed to in one value")
  DigestPrefix & sha256Hex(commitmentPreimage(domain, salt, plaintext))

proc openCommitment*(commitment: string; domain: CommitmentDomain;
                     salt, plaintext: string): bool =
  ## Does this plaintext open this commitment?
  ##
  ## **Producer and auditor side only.** Nothing in the verifier calls
  ## this, and the verifier's entry point has no parameter it could be
  ## called through. An opening is a disclosure; the whole reason the
  ## commitment is in the statement is that a verdict must be reachable
  ## without one.
  commitment == commitTo(domain, salt, plaintext)
