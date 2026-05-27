## Producer -> consumer resource mapping (M82 Phase B).
##
## Seeded from the M69 `CapabilityServiceMap` (driver-internal,
## previously used only by `awaitCapabilityFinalization` to know which
## SCM service a Windows Capability registers and therefore should be
## polled for post-install stability). M82 Phase B promotes the same
## knowledge into a planner-visible resource: the planner consults this
## map to insert IMPLICIT dependency-graph edges from a producer
## resource (e.g. `windows.capability OpenSSH.Server`) to every consumer
## it registers (e.g. `windows.service sshd`) so the topological sort
## emits the producer's op BEFORE the consumer's op WITHOUT the user
## having to write `depends_on` in the profile.
##
## The map is intentionally a small typed const table — not a registry,
## not a config file. Each entry is one declarative fact about an OS
## subsystem's installation side effects. New entries land here as
## further capability / optional-feature / installer side effects are
## identified; the planner picks them up at recompile time.
##
## The shape is GENERIC — a producer is identified by its `kind` and a
## name PREFIX; a producer can register multiple consumers (a future
## Windows Optional Feature like `IIS-WebServerRole` will register a
## seq of services: `w3svc`, `was`, ...). Today only the OpenSSH.Server
## entry is present; the table is sized to grow.
##
## The driver-side `lookupCapabilityService` (the M69 stability-wait
## helper that runs INSIDE the broker after the capability cmdlet
## returns) continues to consult the SAME table via a thin re-export in
## `windows_system_driver.nim` so the seed entry stays a single source
## of truth across the dispatch path and the planner.

import std/strutils

type
  ProducerConsumerEntry* = object
    ## One declarative fact: "a resource of kind `producerKind` whose
    ## name STARTS WITH `producerNamePrefix` registers / configures a
    ## set of consumer resources (each `(consumerKind, consumerName)`)
    ## as a side effect of being installed / applied."
    ##
    ## `producerNamePrefix` is a PREFIX because a number of OS resource
    ## names carry a version-tagged suffix that varies across releases.
    ## The canonical example is a Windows Capability: the user writes
    ## `OpenSSH.Server~~~~0.0.1.0` today and `OpenSSH.Server~~~~0.0.2.0`
    ## on the next Windows release; matching by the `OpenSSH.Server~~~~`
    ## prefix keeps the entry stable across both.
    producerKind*: string
    producerNamePrefix*: string
    consumers*: seq[tuple[kind: string, name: string]]

const
  ProducerConsumerMap*: array[1, ProducerConsumerEntry] = [
    ProducerConsumerEntry(
      producerKind: "windows.capability",
      producerNamePrefix: "OpenSSH.Server~~~~",
      consumers: @[(kind: "windows.service", name: "sshd")])]
    # ----------------------------------------------------------------------
    # Add additional producer -> consumer facts here. Examples that are
    # natural next entries when their gates land:
    #
    #   ProducerConsumerEntry(producerKind: "windows.optionalFeature",
    #     producerNamePrefix: "IIS-WebServerRole",
    #     consumers: @[(kind: "windows.service", name: "w3svc"),
    #                  (kind: "windows.service", name: "was")]),
    #
    #   ProducerConsumerEntry(producerKind: "windows.vsInstaller",
    #     producerNamePrefix: "BuildTools",
    #     consumers: @[(kind: "windows.registryValue",
    #                   name: "HKLM\\SOFTWARE\\Microsoft\\VisualStudio")]),
    # ----------------------------------------------------------------------

proc lookupProducedResources*(producerKind: string;
                              producerName: string):
                              seq[tuple[kind: string, name: string]] =
  ## Return every consumer resource a `(producerKind, producerName)`
  ## pair is known to register. Empty seq when no entry matches — the
  ## common case. Matching is by `producerNamePrefix` (see the type
  ## comment for why prefixes, not exact names).
  ##
  ## A producer may have multiple matching entries in theory; the proc
  ## concatenates every match's `consumers` so the caller sees the
  ## UNION of registered consumers across all matching entries.
  for entry in ProducerConsumerMap:
    if entry.producerKind == producerKind and
       producerName.startsWith(entry.producerNamePrefix):
      for c in entry.consumers:
        result.add(c)

proc lookupCapabilityRegisteredService*(capabilityName: string): string =
  ## Backwards-compatible helper for the M69 CBS-finalization wait in
  ## `windows_system_driver.awaitCapabilityFinalization`. Returns the
  ## single SCM service name a Windows Capability is known to register,
  ## or `""` if none is in the map. When a future capability entry
  ## registers MULTIPLE services this helper returns the FIRST — the
  ## driver's stability wait only needs one to anchor on; the planner
  ## consumes the full `lookupProducedResources` set instead.
  for c in lookupProducedResources("windows.capability", capabilityName):
    if c.kind == "windows.service":
      return c.name
  return ""
