## The service registry's VOCABULARY: the spellings, the provenance enum and
## the instance-attribute row that other modules share with
## `service_registry.nim`, without its codec.
##
## WHY A SEPARATE MODULE. `readiness_edge.nim` binds to these definitions so
## that each has exactly one spelling, and `readiness_edge` is reached from
## provider builds, including nimRtl-shared provider libraries
## (`-d:useNimRtl`). Importing `service_registry` itself brought `std/json`
## into that closure, and the pinned Nim fork emits C for `std/json` under
## `-d:useNimRtl` that does not compile (`Exception` stays an incomplete
## type in `@pjson.nim.c`). This module imports nothing, so a consumer can
## share the vocabulary without the codec. `service_registry` imports and
## re-exports it, so every existing import keeps compiling unchanged.

const
  ServiceRegistrationsTypeId* = "reprobuild.service-registrations"
  ServiceRegistrationsAttrsTypeId* = "reprobuild.service-registrations.v1"
  ServiceRegistrationsAddressSuffix* = "/registrations"
  MintedProvenanceField* = "provenance"
    ## The per-row provenance key, in BOTH documents that carry a minted
    ## identifier: this record's attrs JSON and the dev session's
    ## `shared-instance-registrations.json`. One spelling, bound here,
    ## for `RegistrationAddressSuffix`'s reason -- an invariant
    ## maintained by a sentence is not an invariant.
  InstanceAttributesField* = "instanceAttributes"
    ## Shared-Development-Services §7.3 -- the key the INSTANCE's own
    ## computed attributes live under, in the same two documents, for the
    ## same reason. §7.3's decision is that the issuer URL "travels the
    ## SAME lane as the minted id", and a lane is a store record, a
    ## session document and a point of use; this is the key it occupies
    ## in the first two.

type
  RegistrarProvenance* = enum
    ## Shared-Development-Services §7.2 — WHERE A MINTED IDENTIFIER CAME
    ## FROM, carried with the value rather than inferred from its shape.
    ##
    ## §7.2's defect: the CLI's development registrar derives an id from
    ## `blake3DomainDigest(...)[0 ..< 24]`, and the result is
    ## "indistinguishable, at the point of use, from an id a real issuer
    ## minted. A consumer receives a well-formed identifier that no
    ## issuer has ever heard of, and the failure arrives later, somewhere
    ## else, as an authentication error." A naming convention would not
    ## fix it -- an id is an opaque token and a consumer must not parse
    ## one -- so the fact travels BESIDE the value, like §4.3's
    ## provenance precondition.
    ##
    ## DECLARED HERE, IN THE MODULE THAT OWNS THE DURABLE ROW, and
    ## re-exported by `readiness_edge.nim` where it used to live. The
    ## move is L9 F5's: a stamp that exists only in the process that
    ## minted the value cannot survive a crossing into another project's
    ## session, so `ServiceRegistration` has to carry it -- and
    ## `readiness_edge` already imports this module, so the enum could
    ## not stay there without a cycle. Every existing `import
    ## repro_resources/readiness_edge` still sees the three words,
    ## because that module exports them.
    rprUnstamped = "unstamped"
      ## No registrar claimed this value. Either it was recorded with no
      ## registrar installed, or it was read back from a record written
      ## by a build that predates this field. NEVER read as either of the
      ## other two: `readIssuerMintedResourceAttribute` refuses it, and
      ## so does the `@issuer-minted:` argv token.
    rprDevelopment = "development"
      ## Produced offline, without an issuer. Legitimate -- it is the
      ## default and §7.2 keeps it ("It is the SILENCE that is wrong, not
      ## the fallback") -- and refusable by a consumer that needs the
      ## real thing.
    rprIssuer = "issuer"
      ## The issuer minted it. Reprobuild cannot VERIFY this and does not
      ## pretend to: it is the claim of the project-supplied registrar
      ## that was installed, and it is the claim this library refuses to
      ## let its OWN development registrar make.

proc parseRegistrarProvenance*(word: string): RegistrarProvenance =
  ## The ONE decode of a provenance word, for every document that
  ## carries one.
  ##
  ## AN UNKNOWN WORD IS `unstamped`, NOT A GUESS AND NOT A PARSE
  ## FAILURE. A word this build cannot read is a claim it cannot
  ## evaluate, and the one answer it must not reach for is `issuer`;
  ## `readinessOk` and `serviceCompletionRule` take the same side for the
  ## same reason. The row still resolves through `@minted:`, so a newer
  ## writer cannot break an older reader's offline path.
  ##
  ## AN ABSENT KEY ARRIVES HERE AS `""`, which is also `unstamped` --
  ## the truth about a row written by a build that predates the field.
  result = rprUnstamped
  for candidate in RegistrarProvenance:
    if $candidate == word:
      return candidate

type
  ServiceInstanceAttribute* = object
    ## Shared-Development-Services §7.3 — ONE COMPUTED ATTRIBUTE OF THE
    ## RUNNING INSTANCE, with the same stamp its minted identifiers
    ## carry.
    ##
    ## WHY IT IS STAMPED AT ALL, when an attribute is not "minted". §7.2
    ## reasons about a substituted *identifier*; an issuer URL is not
    ## minted by anybody, so the obvious reading is that provenance does
    ## not apply. It does, and for §7.2's own reason transposed: a WRONG
    ## issuer URL is exactly as silent as a development client id. A
    ## consumer pointed at an issuer that is not the one the instance is
    ## serving fails at authentication time, somewhere else, with
    ## nothing pointing back here. So the question "who told us this"
    ## has to be answerable at the point of use, which means the fact
    ## travels with the value — the same move, the same field.
    ##
    ## STALENESS IS CLOSED STRUCTURALLY AND NOT BY THE STAMP, because
    ## the stamp cannot see time. `reconcileServiceInstanceAttributes`
    ## REPLACES this set wholesale on every converge with what the
    ## currently installed registrar answered, so an attribute survives
    ## only as long as something keeps re-reporting it. That is the
    ## opposite rule from a registration's mint-once reuse, and the
    ## difference is in the values: a client id must be byte-stable
    ## across restarts or last week's configuration breaks, while an
    ## issuer URL legitimately MOVES when the instance rebinds. Reusing
    ## a stored URL would be the `dev-server.sh` descriptor defect L9's
    ## review measured — a registrar answering from the previous run.
    name*: string
    value*: string
    registrar*: string
      ## The `name` of the registrar that reported it. In a refusal this
      ## is the half that says WHO.
    provenance*: RegistrarProvenance
    recordedAtUnix*: int64
