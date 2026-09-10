## The producer plug-in surface — §12's open question, answered.
##
## §12 asks for "the exact recipe signature a third-party format
## producer implements, and how a producer/tool is *registered* so it is
## discoverable, while keeping the built-in set as ordinary
## (non-privileged) instances of it."
##
## The answer is this file, and it is deliberately about twenty lines of
## substance:
##
## ```nim
## type ProducerFn* = proc (dist: Distribution;
##                          site: ToolDependencySite): PackagedArtifact
##                    {.nimcall.}
## ```
##
## That is the whole interface. §6 rule 3 says the producer "interface"
## is *just a recipe signature — ``(typed Distribution) -> artifact
## edge``*, and this is that signature with one addition: ``site``, the
## identity of the calling package, without which a producer could not
## declare its tool as a dependency OF that package (§6 rule 2) and the
## transitive-dependency property would be a claim rather than a fact.
##
## ## Three properties this shape is chosen to have
##
## **1. ``format`` is a string, never an enum.** A ``PackageFormat``
## enum in a shared type would be a closed set — precisely the
## "closed enum baked into" a central place that §6 rule 3 exists to
## forbid — and moving that enum from the engine into the stdlib would
## have moved the problem, not solved it. A third-party producer for
## ``.ipk`` registers the string ``"ipk"`` and no file in this repository
## changes.
##
## **2. The registry is an ordinary module-level ``var``.** Registration
## is a plain proc call at module-init time. The built-in producers
## call it from their own modules with no privileged path, no macro, and
## no compile-time table — which is why "the built-ins are non-privileged
## reference instances" is checkable rather than asserted: delete a
## built-in's ``registerProducer`` line and it stops being discoverable
## by exactly the same mechanism a third party's would.
##
## **3. The engine is not involved, at all.** There is no capability
## query here and none is needed, which settles §12's last open question
## in the negative for M0. "Can this host produce an MSI?" is answered by
## whether ``wix-candle``'s provisioning resolves for the target — an
## ordinary unresolvable dependency, surfaced through the ordinary
## mechanism, exactly as §6.1 requires. Adding a format-agnostic
## discovery query would buy the ability to ENUMERATE producible formats
## without attempting a build; nothing in M0 or M1 needs that, and the
## bar §6.1 sets ("the default assumption is that the engine needs
## nothing packaging-specific at all") is not met by a convenience.

import std/[tables]

import repro_project_dsl

import ./types
import ./runtime_contract

export types, runtime_contract

type
  PackagedArtifact* = object
    ## What a producer returns: one artifact and the edge that makes it.
    format*: string
      ## Format tag — ``"deb"``, ``"tar.gz"``, ``"msi"``. A STRING, for
      ## the reason in the header. Used for diagnostics and registry
      ## lookup, never switched on by the layer.
    path*: string
      ## Build-tree path of the finished artifact.
    edge*: BuildActionDef
      ## The single artifact build edge. Ordinary, content-addressed,
      ## cacheable — §6: "each producer is an ordinary reprobuild build
      ## edge … with a real tool dependency."
    toolSelectors*: seq[string]
      ## The tool packages this producer made the calling project depend
      ## on. Returned rather than merely registered so a test — or a
      ## recipe that wants to print what it pulled in — can read the
      ## claim back instead of taking it on trust.
    tree*: StagedTree
      ## The staged tree the artifact was built from, so a caller can
      ## inspect or further consume it (a checksum edge, a second
      ## producer over the same tree).

  ProducerFn* = proc (dist: Distribution;
                      site: ToolDependencySite): PackagedArtifact {.nimcall.}
    ## The entire producer interface. See the header.

  ProducerRegistration* = object
    format*: string
    description*: string
    fn*: ProducerFn

var producerRegistry: OrderedTable[string, ProducerRegistration]

proc registerProducer*(format, description: string; fn: ProducerFn) =
  ## Make a producer discoverable by format tag.
  ##
  ## Re-registering a format REPLACES the previous entry, deliberately:
  ## §6 rule 3 says a user may "swap the tool behind an existing one",
  ## and the natural way to express that is to register a different
  ## producer under the same tag. Refusing the replacement would make
  ## the built-ins privileged — the one thing rule 3 says they are not.
  producerRegistry[format] = ProducerRegistration(
    format: format, description: description, fn: fn)

proc registeredProducers*(): seq[ProducerRegistration] =
  for _, reg in producerRegistry:
    result.add(reg)

proc registeredProducerFormats*(): seq[string] =
  for format, _ in producerRegistry:
    result.add(format)

proc hasProducer*(format: string): bool =
  format in producerRegistry

proc produce*(format: string; dist: Distribution;
              site = noSite()): PackagedArtifact =
  ## Run the producer registered for ``format``.
  ##
  ## An unknown format raises here rather than returning a sentinel: a
  ## typo in a format tag is a recipe bug, and the failure should name
  ## the tags that DO exist — which is also the closest thing this layer
  ## has to a capability query, and it is a pure user-space lookup over
  ## a user-space table.
  if format notin producerRegistry:
    var known = ""
    for f, _ in producerRegistry:
      if known.len > 0: known.add(", ")
      known.add(f)
    raise newException(ValueError,
      "no packaging producer registered for format '" & format &
      "'; registered formats: " & (if known.len > 0: known else: "(none)"))
  producerRegistry[format].fn(dist, site)

proc artifactFileName*(dist: Distribution; extension: string): string =
  ## The conventional artifact file name for a format extension.
  ##
  ## Each producer overrides where its ecosystem disagrees (deb wants
  ## ``_`` separators and the Debian arch spelling; rpm wants dots).
  ## This is the fallback the simple formats use.
  dist.name & "-" & dist.fullVersion & "-" & dist.architecture & extension
