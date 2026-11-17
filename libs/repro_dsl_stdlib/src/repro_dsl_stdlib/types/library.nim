## DSL-port M9.R.2b — typed ``Library`` value layer.
##
## The stdlib's Layer-1 high-level constructors (``c_library`` /
## ``nim_library`` / multi-artifact ``meson_package.library(name)`` /
## etc.) and Layer-2 operation overloads (``link(kind = lokShared)``)
## return ``Library`` values. The package macro currently still injects
## ``DslArtifact`` placeholders for ``library <name>:`` declarations
## (M9.R.5 / a follow-up will move the slot type itself onto ``Library``
## via the package macro); for now recipe authors capture the
## constructor return value into a local ``let`` binding and the
## auto-lift mechanism reads the ``api:`` metadata via the explicit
## ``into = "<n>"`` parameter (see the per-constructor signatures).
##
## See [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Typed-value layer" for the catalogue + the per-field contract.

import repro_project_dsl

type
  Library* = object
    ## DSL-port M9.R.2b typed-value layer record. Returned by the
    ## Layer-1 high-level constructors (``c_library``, ``nim_library``,
    ## ``MesonPackageResult.library``, ...) and the Layer-2 ``link``
    ## overload when the link target is a library.
    api*: LibraryApi
      ## Auto-lifted ``library <name>: api:`` block contents (M9.R.3
      ## landed the ``api:`` block; the constructor populates this slot
      ## by calling ``registeredLibraryApi(activePackageName,
      ## into)``). Empty (with ``declared == false``) when the
      ## surrounding library declaration has no ``api:`` block.
    install*: BuildActionDef
      ## The producing ``BuildEdge`` — typically a link or install
      ## edge whose ``call.subcommand`` is the per-compiler ``link``
      ## or ``install`` call.
    soname*: string
      ## Lifted from ``api.soname`` at construction time so consumers
      ## don't have to reach through ``api``. This is the BASE name
      ## (``foo``), not the full SONAME, which ``sharedLibrarySoname``
      ## derives from it and ``sover``. Empty when the ``api:`` block
      ## did not declare ``soname``.
    sover*: string
      ## Lifted from ``api.sover``. Empty when omitted from ``api:``.
    linkKind*: LibraryLinkKind
      ## Lifted from ``api.linkKind``. ``llkUnset`` when the ``api:``
      ## block omitted ``linkKind`` (or declared no ``api:`` block).
    linkTimeName*: BuildActionDef
      ## The edge that writes the link-time name ``lib<base>.so`` as a
      ## symlink to the file named by the SONAME, so ``-l<base>`` still
      ## resolves at link time. Default (empty ``id``) when the SONAME
      ## already is ``lib<base>.so`` or the library is not a shared ELF
      ## object -- there is then no second name to write.
    installPrefix*: string
      ## Relative path within the install destdir (e.g.
      ## ``"usr/lib"``). Empty when the producing edge is not a
      ## destdir-staged install action.

proc sharedLibrarySoname*(soname, sover: string): string =
  ## The full ELF SONAME of a shared library whose ``api:`` block
  ## declares base name ``soname`` and SOVERSION ``sover``:
  ## ``lib<soname>.so``, plus ``.<sover>`` when ``sover`` is non-empty.
  ##
  ## A consumer linked against the library records this string as its
  ## ``DT_NEEDED`` and the dynamic loader opens a file of exactly this
  ## name, so the library is written under it and ``lib<soname>.so`` is
  ## only a link-time symlink (C-Cpp.md §"Mode A — Fine-grained build
  ## graph (primary)"; https://tldp.org/HOWTO/Program-Library-HOWTO/shared-libraries.html).
  result = "lib" & soname & ".so"
  if sover.len > 0:
    result.add("." & sover)

proc newLibrary*(install: BuildActionDef;
                 api: LibraryApi = LibraryApi(declared: false);
                 installPrefix = ""): Library =
  ## Convenience constructor — populates the scalar lift-out fields
  ## from ``api`` so callers don't have to restate them.
  Library(
    api: api,
    install: install,
    soname: api.soname,
    sover: api.sover,
    linkKind: api.linkKind,
    installPrefix: installPrefix)
