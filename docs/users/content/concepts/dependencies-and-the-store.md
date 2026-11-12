---
title: Dependencies and the store
description: How a project names the tools and libraries it depends on, how reprobuild chooses one version of each, and where it keeps what it obtains.
kind: explanation
persona: build-maintainer
order: 15
verifies:
  commands: [build, lock update, why, store list, store gc]
  tests:
    - tests/integration/t_uses_resolves_sqlite3_from_real_reprobuild_packages.nim
    - tests/integration/t_integration_solver_resolves_variants.nim
    - libs/repro_solver/tests/t_explainer_unsat_version_range.nim
    - tests/integration/t_lock_update_rewrites_exact_pin_in_both_recipes.nim
    - tests/e2e/gm4b/t_e2e_home_apply_realizes_nix_selection.nim
    - tests/integration/t_integration_local_store_gc.nim
unverified:
  - claim: "--tool-provisioning overrides REPRO_TOOL_PROVISIONING, which overrides the package's defaultToolProvisioning."
    reason: "Read from the CLI's provisioning resolution; no test checks the order."
    owner: unassigned
  - claim: "Two versions of one tool stay in the store side by side, and installing one does not replace the other."
    reason: "Follows from content-derived store names; no test installs two versions of one tool and checks that both remain."
    owner: unassigned
---

# Dependencies and the store

This page explains how a project names what it depends on, how reprobuild turns
those names into exact versions, and where it keeps what it obtains.

## A project names ranges, not versions

A package in `repro.nim` lists the tools and libraries it uses, each with a
version range such as `"nim >=2.2 <3.0"`. The range states which versions the
package works with. It does not pick one, so the project file stays correct when
a new release inside the range appears.

A package can name everything in one `uses:` list, or keep three lists apart:
the tools that run during the build (`nativeBuildDeps`), the libraries its
programs link against (`buildDeps`) and what those programs need when they run
(`runtimeDeps`). A compiler, a code generator and a database server are all
packages with versions, whichever list names them.

## The catalog says how to obtain each package

A name such as `sqlite3` refers to a package definition in a catalog. The public
catalog is [reprobuild-packages](https://github.com/metacraft-labs/reprobuild-packages).
A definition lists the versions it can provide and how to obtain or build each
one, so one definition serves every project that names the package, whatever
range it asks for. A repository can carry a catalog of its own, and reprobuild
consults it as well as the public one.

## A solver chooses one version of each

Before a build, reprobuild collects the ranges that every package in it asks for
and passes them to a constraint solver. The solver chooses one version of each
dependency that satisfies all of them, together with the build options, called
variants, that the packages require. When no choice satisfies every range, the
solver reports the requirement it could not meet instead of picking a version
outside it.

## The lock file records the choice

The result goes into the lock file, `repro.lock`, which the repository commits.
A build on another machine reads the same lock, so it uses the same versions and
the same source revisions.

To move a dependency on purpose, run `repro lock update <dependency>`, with
`--to <revision>` to name the revision. It rewrites an exact pin wherever a
project file states one, refuses a revision that a stated range excludes, and
writes nothing unless it can write every file it has to change. To find out why a
dependency is in the build at all, run `repro why <package>`.

## Where the tools come from

Tool provisioning decides how reprobuild obtains each chosen version: from your
`PATH`, from Nix, from a release tarball, from Scoop on Windows, or by building
it from source. A package states its default with `defaultToolProvisioning`, and
the `--tool-provisioning` option or the `REPRO_TOOL_PROVISIONING` variable
overrides it.

Provisioning from Nix or Scoop uses the package manager you already run. A tool
that Nix provides stays in the Nix store, and reprobuild records where it is
instead of copying it. Adopting reprobuild does not mean reinstalling what those
tools manage.

## The store keeps each result under its own name

What reprobuild builds or obtains goes into its store, a directory in which each
entry's name is derived from its contents. An entry with a different version or
different contents gets a different name, so a project that needs an older
version keeps it while another project uses a newer one.

`repro store list` shows the entries. `repro store gc` removes the ones nothing
refers to any more: it moves each to a pending-deletion area first and deletes it
after a grace period, and it records each decision.

## What this does not cover

- `repro` has no command that searches the catalog.
- The solver chooses among the versions the catalog defines. A version that no definition lists cannot be chosen, even when a range admits it.

## Related

- [How reprobuild works](how-reprobuild-works.md)
- [How caching stays correct](how-caching-stays-correct.md)
- [Coming from Nix](../coming-from/nix.md)
- [Glossary: Catalog](../reference/glossary.md#catalog), [Lock file](../reference/glossary.md#lock-file), [Store](../reference/glossary.md#store), [Tool provisioning](../reference/glossary.md#tool-provisioning)
