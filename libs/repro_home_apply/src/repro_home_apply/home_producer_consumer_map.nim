## Producer -> consumer resource mapping for HOME-SCOPE resources
## (M82 home-scope follow-up).
##
## Structural mirror of `libs/repro_elevation/src/repro_elevation/`
## `producer_consumer_map.nim` (the system-scope table), but the table
## itself is INTENTIONALLY EMPTY today — none of the six home-scope
## resource kinds (`env.userPath`, `fs.managedBlock`,
## `shell.integration`, `env.userVariable`, `windows.registryValue`,
## `windows.startup`) is known to register another home-scope resource
## as a side effect of being applied. The shape is in place so the
## home planner code path is symmetric with the system one: it still
## calls `lookupProducedResources` for every resource (and gets back
## an empty seq), so adding the first home-scope implicit edge later
## is purely a data-table change.
##
## See the system-scope module for the conceptual model. The shape is
## kept byte-identical so a future DRY refactor (one shared
## producer-consumer module across home + system) is a mechanical
## merge rather than a redesign.

import std/strutils

type
  ProducerConsumerEntry* = object
    ## One declarative fact: "a home resource of kind `producerKind`
    ## whose name STARTS WITH `producerNamePrefix` registers /
    ## configures a set of consumer resources (each
    ## `(consumerKind, consumerName)`) as a side effect of being
    ## applied."
    ##
    ## `producerNamePrefix` is a PREFIX for the same reason it is in
    ## the system table: it lets a single entry stay stable across
    ## version-tagged name suffixes. (No home-scope resource exhibits
    ## that pattern today, but the shape is shared with system scope.)
    producerKind*: string
    producerNamePrefix*: string
    consumers*: seq[tuple[kind: string, name: string]]

const
  ProducerConsumerMap*: seq[ProducerConsumerEntry] = @[]
    ## Empty today — no home-scope producer/consumer facts known.
    ## Add entries here as further home-scope side-effect relations
    ## are identified; the home planner picks them up at recompile
    ## time without any code change.
    ##
    ## A natural future entry, for illustration:
    ##
    ##   ProducerConsumerEntry(
    ##     producerKind: "shell.integration",
    ##     producerNamePrefix: "bash-rc",
    ##     consumers: @[(kind: "env.userPath", name: "user-bin")]),
    ##
    ## would order a `shell.integration` block before the
    ## `env.userPath` resource it expects to consume.

proc lookupProducedResources*(producerKind: string;
                              producerName: string):
                              seq[tuple[kind: string, name: string]] =
  ## Return every consumer home resource a `(producerKind, producerName)`
  ## pair is known to register. Empty seq today (the table is empty);
  ## kept as the planner's single entry point so adding the first home
  ## producer/consumer entry never changes the planner's API. Matching
  ## is by `producerNamePrefix` (see the type comment for why prefixes,
  ## not exact names).
  for entry in ProducerConsumerMap:
    if entry.producerKind == producerKind and
       producerName.startsWith(entry.producerNamePrefix):
      for c in entry.consumers:
        result.add(c)
