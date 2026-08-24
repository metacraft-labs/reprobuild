# repro_fs_facts

Declared facts about operating systems and filesystems.

Spec: `reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org`
(**F1** the tables, **F2** the conformance suite).

Two tables, because the axes are independent — a property belongs either
to the OS (is symlink creation privileged? how long may a command line
be?) or to the filesystem (is there a reflink? how many names may one
file have?). A host is a *pair*.

## A fact is not a constant

Every entry carries three things:

| part | why |
|------|-----|
| **value** | in a type that can say `varies` or `unknown` rather than forcing a guess |
| **citation** | the vendor doc or standard that states it, so a reader can check it without a machine |
| **observability** | how a test falsifies it — or an explicit statement that it cannot be observed from user space |

The third is the point. The milestone states the rule this library
enforces: *a constant that no test can falsify is worse than no
constant, because policy will rely on it.* So
`tests/t_fs_facts_conformance.nim` drives every `obOperation` and
`obQuery` marker against whatever filesystems the host actually offers,
reports the rest as **untested here** rather than as passing, and fails
naming both values when a constant and reality disagree.

## This library does not probe

| question | answered by | example |
|----------|-------------|---------|
| What can this filesystem do? | **this library** | NTFS has no reflink; it caps a file at 1024 names |
| Does this operation work between THESE two paths? | `repro_local_store/link_capability` | Btrfs `link()` across subvolumes fails `EXDEV` on one device |

Neither replaces the other. Constants cannot know which subvolume a path
is in; a probe knows nothing about a filesystem this host does not have.
`detect.nim` maps a path to a table row by asking the OS for the
filesystem's *name* — a lookup, never a capability verdict.

## Layout

    src/repro_fs_facts.nim                    facade
    src/repro_fs_facts/fact.nim               the schema
    src/repro_fs_facts/filesystems.nim        the filesystem table
    src/repro_fs_facts/operating_systems.nim  the OS table
    src/repro_fs_facts/detect.nim             path -> table row, plus the
                                              limits/flags the OS advertises

Dependencies: `std/[os, strutils]` and the platform bindings only.
Nothing from this repository, so the store — which is a consumer — can
import it without a cycle.

## Adding an entry

Add the enum member, add one literal to the table, and list the strings
the OS reports for it in `names`. The conformance suite picks it up with
no further change. A value you cannot source **must** be `tnUnknown` /
`unknownQuantity()` with `pvUnestablished` — never a plausible guess.
