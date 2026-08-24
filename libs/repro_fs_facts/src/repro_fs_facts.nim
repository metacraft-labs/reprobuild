## repro_fs_facts — declared OS and filesystem facts.
##
## Spec: ``reprobuild-specs/Platform-And-Filesystem-Facts.milestones.org``
##       (**F1** the tables, **F2** the conformance suite).
##
## Two tables, because the axes are independent — a property belongs
## either to the operating system (is symlink creation privileged? how
## long may a command line be?) or to the filesystem (is there a
## reflink? how many names may one file have?) — and a host is a *pair*.
##
## Every fact carries a value, a citation, and an observability marker;
## ``fact.nim`` explains why the last two exist and
## ``tests/t_fs_facts_conformance.nim`` is what gives them force.
##
## **What this library is not.** It does not probe. The question "does
## this operation work between THESE two paths?" belongs to
## ``repro_local_store/link_capability``, which answers it by attempting
## the operation, and this library neither replaces nor wraps it. The
## two answer different questions and both are needed: constants cannot
## know which Btrfs subvolume a path is in, and a probe cannot say
## anything about a filesystem the host does not have.
##
## **Placement.** A dedicated library rather than a module inside
## ``repro_local_store`` or ``repro_platform``:
##
## * ``repro_local_store`` would make every consumer of a filesystem
##   fact depend on SQLite, the store's prefix/receipt surface and its
##   Layer-2 recovery paths. The facts are cross-cutting — the engine,
##   the CLI, the home/system apply paths and the caches all branch on
##   them — so hanging them off the store would invert the dependency.
## * ``repro_platform`` is not a leaf: it carries the MSVC dev-env
##   activation, which reaches ``std/osproc`` and spawns ``cmd.exe``. A
##   library of constants must not drag a process launcher in behind it.
##
## What is here imports ``std/[os, strutils]`` (plus ``winlean`` /
## ``posix`` for the OS queries) and nothing else in this repository, so
## it can be imported from anywhere including the store itself.

import repro_fs_facts/fact
import repro_fs_facts/filesystems
import repro_fs_facts/operating_systems
import repro_fs_facts/detect

export fact
export filesystems
export operating_systems
export detect
