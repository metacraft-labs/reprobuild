## ``repro_lock_gen/metadata_objects`` — the retrieved metadata object, and
## the IN-PROCESS path that retrieves it.
##
## Named-Lock-Files NLF-M5 (design §5.6), against
## `Repository-And-Index-Format.md` §"Refresh Is Performed By Graph Edges" and
## `Sandbox-And-Monitoring.md` §"The Network Dimension" (both amended
## 2026-08-21).
##
## ## Why this module exists separately from the generation driver
##
## Two reasons, and the second is the load-bearing one.
##
## 1. The wire format of a metadata object and the *policy* under which it may
##    be reached are one concern; which objects a particular solve needs is
##    another.
## 2. **The bootstrap constraint has to be checkable.** §5.6: "the metadata
##    fetcher must ride the **in-process** path … A metadata fetch MUST NOT
##    shell out to a solved `curl`." That is not a style preference — a fetch
##    that needs a solved tool cannot run before the solve that produces it,
##    which is the third of the three circularities §5.6 dissolves. Confining
##    every byte of retrieval to this module makes the constraint a
##    one-directory grep rather than a promise: this file imports
##    `repro_binary_cache_client/http_pool` and NOTHING from `std/osproc`, and
##    a future edit that reached for a subprocess would have to add the import
##    here in plain sight.
##
## ## The object format
##
## A **version-metadata record**: the list of published versions of one
## package, one per line, `#`-comments and blank lines ignored. Deliberately
## the smallest object in `Repository-And-Index-Format.md`'s list that the
## solve actually consults — the encoder's candidate universe comes from
## `PackageDecl.versions`, and `repro_solver/version_encoder`'s own header
## records the gap this closes: "The candidate list comes directly from the
## ``PackageDecl.versions`` field — M2c does not (yet) fetch a remote
## catalog."
##
## The richer objects that document enumerates (root manifest, index shards,
## acquisition records, curator snapshot indexes) are the same shape — one
## `netFetch` edge per retrieved object, content-addressed by what it
## retrieved — and are not implemented here. Stated rather than implied: this
## module ships ONE object kind.
##
## ## Content addressing, and what "after the fact" means
##
## §5.6: "a Nix fixed-output derivation declares its expected hash *in
## advance*, whereas a metadata fetch cannot — discovering what is new is the
## purpose. So the fetch edge is content-addressed **after the fact**." So
## `fetchMetadataObject` returns the digest of what it actually retrieved, and
## that digest is the edge's evidence. Nothing here compares it against an
## expectation, because there is none to compare against.

import std/[strutils]

import repro_binary_cache_client/http_pool
import repro_multihash

type
  MetadataFetchError* = object of CatchableError
    ## The object could not be retrieved. Raised rather than returning an
    ## empty version list: an empty list is a legitimate answer ("this package
    ## has no published versions") and a failure that rendered as one would
    ## make the solve report UNSAT for a network problem.

  RetrievedMetadata* = object
    ## What one `bakMetadataFetch` edge retrieved.
    url*: string
      ## The destination actually reached. Half the evidence
      ## `Sandbox-And-Monitoring.md` §"The Network Dimension" specifies for a
      ## `netFetch` edge ("the content digest of what it retrieved plus the
      ## recorded destination set").
    body*: string
    integrity*: string
      ## The other half: a self-describing `blake3:<hex>` digest over the
      ## retrieved bytes, computed AFTER retrieval.

var metadataFetchAttemptCount {.threadvar.}: int
  ## How many times this thread has ATTEMPTED to reach a metadata destination.
  ##
  ## Attempts, not successes, and the distinction is the whole value of the
  ## counter. Corpus case NLF-GEN-7 requires a pinned build to attempt no
  ## metadata fetch; a counter incremented on success would read zero for a
  ## build that tried and failed, which is the exact outcome the case must
  ## distinguish from "never tried". It is incremented before the socket is
  ## touched, so a connection refused still counts.

proc metadataFetchAttempts*(): int =
  ## The running attempt count for this thread. Read by NLF-GEN-7.
  metadataFetchAttemptCount

proc resetMetadataFetchAttempts*() =
  metadataFetchAttemptCount = 0

proc metadataObjectUrl*(endpoint, packageName: string): string =
  ## The URL of one package's version-metadata record under `endpoint`.
  ##
  ## One naming rule, used by both the planner and the executor, so a plan
  ## cannot name an object the executor would look for somewhere else.
  endpoint.strip(leading = false, chars = {'/'}) & "/" & packageName &
    ".versions"

proc metadataDestinationOf*(endpoint: string): string =
  ## The tracked fetch destination a fetch against `endpoint` declares —
  ## scheme, host, port and path prefix, per the amendment's "A destination is
  ## named by scheme, host, optional port, and optional path prefix … so that
  ## 'this edge may reach the package index at `https://index.example/`' is
  ## expressible without granting the host generally."
  endpoint.strip(leading = false, chars = {'/'}) & "/"

proc renderVersionList*(versions: openArray[string]): string =
  ## The canonical on-the-wire body for a version-metadata record.
  result = ""
  for v in versions:
    result.add(v & "\n")

proc parseVersionList*(body: string): seq[string] =
  ## Read a version-metadata record. Blank lines and `#` comments are ignored;
  ## order is preserved as published.
  result = @[]
  for raw in body.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    result.add(line)

proc fetchMetadataObject*(url: string): RetrievedMetadata =
  ## Retrieve one metadata object over the IN-PROCESS fetch path.
  ##
  ## `Binary-Caches.md` (cited by §5.6) notes that "the main `repro` binary
  ## links TLS specifically so its embedded `substituteInProcess` →
  ## `http_pool` path can reach an `https://` cache while realizing a solved
  ## graph". This is the second consumer of that path and the reason it must
  ## be the same one: a metadata fetch has no solved tool available to it.
  ##
  ## The attempt is counted BEFORE the socket is opened, so a build that tried
  ## and failed is distinguishable from one that never tried.
  inc metadataFetchAttemptCount
  let pool = newHttpPool(maxConnections = 4)
  try:
    let resp =
      try:
        pool.getEntireBody(url)
      except CatchableError as err:
        raise newException(MetadataFetchError,
          "metadata fetch failed for " & url & ": " & err.msg)
    if resp.statusCode != 200:
      raise newException(MetadataFetchError,
        "metadata fetch for " & url & " returned HTTP " & $resp.statusCode)
    var body = newString(resp.body.len)
    for i, b in resp.body:
      body[i] = char(b)
    RetrievedMetadata(url: url, body: body,
      integrity: narStyleTreeMultihash(@[(path: "body", content: body)]))
  finally:
    pool.close()
