## Source-from-tarball meson recipe — M9.N Batch C build-tool slice.
##
## meson is a Python-based meta-build system: the on-disk artefact is
## a ``meson`` wrapper script (``$PREFIX/bin/meson``) that ``exec``s the
## host's ``python3`` interpreter against the bundled ``mesonbuild``
## package source. There is no C / C++ compilation step, no
## ``./configure`` script, and no ``Makefile`` — the upstream tarball
## ships a ``setup.py`` (setuptools-style) plus the ``mesonbuild/``
## Python package tree, and "installing" amounts to copying the package
## tree into ``$PREFIX/lib/python3.X/site-packages/mesonbuild/`` and
## writing the wrapper script.
##
## ## Honest deferral — convention gap for Python-tool recipes
##
## None of the four ``from-source-*`` conventions that ship in the
## standard provider today (``from-source-meson`` / ``from-source-cmake``
## / ``from-source-autotools`` / ``from-source-make``) can claim this
## recipe:
##
##   * ``from-source-meson`` requires ``uses:`` to list ``meson`` AND
##     ``mesonOptions:`` to be populated; we'd be bootstrapping meson
##     via meson, which is the chicken-and-egg.
##   * ``from-source-cmake`` requires ``cmakeFlags:`` populated.
##   * ``from-source-autotools`` requires ``configureFlags:`` populated.
##   * ``from-source-make`` requires ``makeFlags:`` populated.
##
## meson's upstream build shape is ``python3 setup.py install --root
## <stage> --prefix /usr`` (or, equivalently, ``pip install --root
## <stage> --prefix /usr meson==<version>``). The flag-channel taxonomy
## the DSL ships (``meson`` / ``cmake`` / ``configure`` / ``make`` /
## ``ninja``) has no ``setup.py`` / ``pip``  channel that would let a
## future convention pick this recipe up off a flag-discriminator alone.
## Two follow-up shapes can close the gap:
##
##   * Add a new ``from-source-python-tool`` convention (Tier 2b) that
##     recognises ``uses: "python3"`` plus a single ``executable``
##     member declared with no flag block — emits a fetch action +
##     ``python3 -m pip install --root <stage> --prefix /usr
##     <extractedRoot>`` + stage-copy of ``<stage>/usr/bin/<member>``
##     to ``<projectRoot>/.repro/output/<member>/<member>``.
##   * Or widen the DSL with a ``build:`` block (Tier 1, per the task
##     brief's vocabulary) so this recipe can drop to a custom shell
##     sequence (``tar -xf …; cp -r mesonbuild $output/share/meson/;
##     printf '#!/bin/sh\nexec python3 …' > $output/bin/meson; chmod
##     +x …``). The DSL today does NOT expose such a surface — the
##     top-level project ``build:`` block (e.g. ``reprobuild/repro.nim``
##     line 243) registers typed-output edges via Nim procs, NOT
##     arbitrary shell strings. A new ``build: shell "<cmd>"`` action
##     surface would need ``libs/repro_project_dsl`` + the engine's
##     action vocabulary widened first.
##
## v1 of THIS recipe therefore registers fetch + versions + executable
## artifact ONLY, and ships zero flag blocks on every channel. The
## smoke test pins the registry round-trip + the four-channel empty
## state so a future convention or DSL widening can flip this recipe to
## "claimed" without re-touching it.
##
## ## Why meson matters for the v1 desktop story
##
## meson is the dominant modern meta-build system for the C / C++
## desktop stack — every recipe in ``recipes/packages/source/`` that
## drives ``meson setup`` consumes the ``meson`` executable at build
## time. Direct consumers in the existing source corpus include
## ``dbus-broker`` (the M9.L.0 vertical-slice recipe), ``glib2``,
## ``gdk-pixbuf``, ``pipewire``, ``wireplumber``, ``wayland``,
## ``wlroots``, ``sway``, ``gnome-shell``, ``mutter``, ``pango``, and
## ``systemd``. Bootstrapping meson from source closes the
## ``meson >=1.3`` toolchain floor those recipes pin without relying on
## the stdlib catalog's Scoop / nix provisioning fast path.
##
## ## sha256 strategy
##
## The fetch URL points at the upstream GitHub release tarball
## ``meson-1.6.1.tar.gz``. The sha256 was computed by downloading the
## tarball once from the upstream URL (recorded in ``versions:``
## above):
##
##   sha256 = 1eca49eb6c26d58bbee67fd3337d8ef557c0804e30a6d16bfdf269db997464de
##
## Tarball size = 2,276,144 bytes. The ``vendor/`` directory is reserved
## for a follow-up vendoring pass mirroring the existing
## ``recipes/packages/source/bash/vendor/`` precedent; v1 of the recipe
## ships the upstream URL directly so the fetch-action's argv carries
## a real, verifiable hash even before vendoring lands.
##
## ## Version choice — 1.6.1
##
## meson releases are cut on github.com/mesonbuild/meson under tags of
## the form ``<X>.<Y>.<Z>``. 1.6.1 is the current stable in the 1.6.x
## line as of mid-2026 and satisfies every existing
## ``uses: "meson >=1.3"`` pin in the source corpus.
##
## ## Artifacts
##
## meson exposes a single load-bearing CLI binary on disk:
##
##   * ``meson``  — ``$PREFIX/bin/meson``, the wrapper script the C /
##                   C++ recipes invoke at ``meson setup`` /
##                   ``meson compile`` / ``meson install`` time.
##
## ## Configurables
##
## v1 ships NO configurables and NO flag-block declarations: meson's
## upstream install path takes no build-system flags, and a future
## ``from-source-python-tool`` convention (or ``build: shell ...``
## widening) will lower the recipe into an install action without
## needing a flag channel.

import repro_project_dsl
# DSL-port M9.R.2c — pulls ``Library`` / ``Executable`` into scope for
# the typed artifact slot vars the ``package`` macro injects.
import repro_dsl_stdlib/types
# DSL-port M9.R.10a — bring the system-tool stdlib package set into
# scope so the project-interface extractor (``toInterfaceToolUse``)
# finds the provisioning blocks declared on the stdlib python3 package
# and threads them onto the meson recipe's
# ``nativeBuildDeps: "python3 >=3.8"`` use. Without this import the
# provisioning blocks would be invisible at extract time and the
# from-source resolver would hard-fail with "no stdlib provisioning
# channel declared on the tool use".
import repro_dsl_stdlib/packages/system_tools

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package mesonSource:
  ## From-source meson — M9.N Batch C build-tool slice.
  ##
  ## REGISTRATION-ONLY recipe: see the module doc-comment's "Honest
  ## deferral" section. None of the four existing ``from-source-*``
  ## conventions claims this recipe; the smoke test pins the M9.H
  ## fetch round-trip + M9.I four-channel empty-state + M3 single-
  ## executable artifact registration so a future convention (or DSL
  ## ``build: shell ...`` widening) can attach without touching the
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com release tarball URL; ``sourceRepository`` points at
    ## the canonical project tree.
    "1.6.1":
      sourceRevision = "1.6.1"
      sourceUrl = "https://github.com/mesonbuild/meson/releases/download/1.6.1/meson-1.6.1.tar.gz"
      sourceRepository = "https://github.com/mesonbuild/meson"

  fetch:
    ## Live upstream URL. The vendor/ directory is reserved for a
    ## follow-up vendoring pass (the bash / ncurses / vim precedents
    ## vendor the tarball under ``recipes/packages/source/<pkg>/vendor/``
    ## and rewrite the URL to ``file:///...``); v1 of this recipe ships
    ## the upstream URL directly because the meson tarball is hosted on
    ## a stable GitHub release endpoint (vs the brittle zlib.net /
    ## ftp.gnu.org mirror lifecycle the vendoring precedents target).
    ##
    ## sha256 was computed by downloading the tarball once from this
    ## URL (2,276,144 bytes).
    url: "https://github.com/mesonbuild/meson/releases/download/1.6.1/meson-1.6.1.tar.gz"
    sha256: "1eca49eb6c26d58bbee67fd3337d8ef557c0804e30a6d16bfdf269db997464de"
    extractStrip: 1

  nativeBuildDeps:
    ## python3 is the runtime interpreter the ``meson`` wrapper script
    ## execs against the bundled ``mesonbuild`` package source. The
    ## upstream tarball ships pure-Python code with no native
    ## extensions, so no C toolchain is required at install time —
    ## extracting + copying + writing a wrapper script is sufficient.
    ## DSL-port M9.R.10a — the stdlib package + provisioning lives
    ## under ``python3`` (the POSIX command name); align the recipe
    ## constraint to the canonical name so the resolver finds the
    ## scoop / nix / tarball channels declared on the stdlib package.
    "python3 >=3.8"

  executable meson:
    ## ``$PREFIX/bin/meson`` — the wrapper script that ``exec``s the
    ## bundled ``mesonbuild`` Python package via the host's
    ## ``python3``. Consumed by every C / C++ recipe in
    ## ``recipes/packages/source/`` that declares ``uses: "meson"``
    ## (dbus-broker, glib2, gdk-pixbuf, pipewire, wireplumber, wayland,
    ## wlroots, sway, gnome-shell, mutter, pango, systemd, etc).
    ##
    ## M9.N Batch C.1 — install body via the new ``shell()`` action
    ## surface on ``build:`` blocks. The new ``from-source-custom``
    ## convention claims this recipe (no flag channels declared, one or
    ## more shell actions registered) and emits one ``BuildActionDef``
    ## per shell line. ``$extracted`` resolves to ``<projectRoot>/src/``
    ## (where the fetch action extracted the tarball); ``$out`` resolves
    ## to ``<projectRoot>/.repro/build/from-source-custom/mesonSource/``
    ## (the per-package output root the stage-copy action probes for
    ## ``bin/meson``).
    build:
      # Lay out the on-disk install tree the wrapper script expects.
      shell "mkdir -p $out/share/meson $out/bin"
      # Copy the bundled ``mesonbuild`` Python package into the
      # share dir.
      shell "cp -r $extracted/mesonbuild $out/share/meson/"
      # Write the wrapper script — execs the bundled package via
      # ``python3``. The double-quoted shell heredoc keeps the
      # ``$@``/``$out`` placeholders distinguishable: ``$out`` is the
      # DSL substitution (resolved at emit time), ``$@`` is the shell
      # variable expanded at run time.
      shell "printf '#!/bin/sh\\nexec python3 %s/share/meson/__main__.py \"$@\"\\n' \"$out\" > $out/bin/meson"
      # Make the wrapper executable so the stage-copy step finds a
      # runnable binary.
      shell "chmod +x $out/bin/meson"

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
