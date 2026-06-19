## Source-from-tarball ninja recipe — M9.N Batch C build-tool slice.
##
## ninja is a small C++ build system with a focus on speed. The
## upstream build is bootstrapped via a Python driver:
##
##   python3 configure.py --bootstrap
##
## This compiles the C++ sources (re2c-generated lexer + the
## ``src/*.cc`` core) into a self-hosting ``ninja`` binary at the
## source root, which is then copied to ``$PREFIX/bin/ninja``.
##
## ## Honest deferral — convention gap for bootstrap-driven recipes
##
## None of the four ``from-source-*`` conventions that ship in the
## standard provider today (``from-source-meson`` / ``from-source-cmake``
## / ``from-source-autotools`` / ``from-source-make``) can claim this
## recipe:
##
##   * ``from-source-meson`` requires ``uses:`` to list ``meson`` AND
##     ``mesonOptions:`` to be populated; we'd be bootstrapping ninja
##     via meson+ninja, which is the chicken-and-egg.
##   * ``from-source-cmake`` requires ``cmakeFlags:`` populated.
##     ninja ALSO ships a ``CMakeLists.txt`` for cross-compilation
##     scenarios, but the canonical / endorsed upstream path is
##     ``configure.py --bootstrap``; using cmake here would pull in a
##     cmake host-toolchain dependency we don't yet have bootstrapped.
##   * ``from-source-autotools`` requires ``configureFlags:`` populated
##     AND the existence of an autotools-style ``./configure`` script
##     — ninja's ``configure.py`` is a Python driver, NOT an autoconf-
##     generated shell script, so the channel taxonomy doesn't map.
##   * ``from-source-make`` requires ``makeFlags:`` populated. ninja's
##     bootstrap does NOT drive ``make`` — it compiles the C++ sources
##     directly via the Python driver.
##
## ninja's upstream build shape is ``python3 configure.py --bootstrap``
## followed by ``install -Dm555 -t $out/bin ninja``. The flag-channel
## taxonomy the DSL ships (``meson`` / ``cmake`` / ``configure`` /
## ``make`` / ``ninja``) has no ``bootstrap.py`` channel that would let
## a future convention pick this recipe up off a flag-discriminator
## alone. Two follow-up shapes can close the gap:
##
##   * Add a new ``from-source-python-bootstrap`` convention (Tier 2b)
##     that recognises ``uses: "python3"`` + ``executable`` member +
##     no flag block — emits ``python3 configure.py --bootstrap`` +
##     stage-copy of the resulting binary.
##   * Or widen the DSL with a ``build:`` block (Tier 1, per the task
##     brief's vocabulary) so this recipe can drop to a custom shell
##     sequence (``tar -xf …; python3 configure.py --bootstrap;
##     install -Dm755 ninja $output/bin/ninja``). The DSL today does
##     NOT expose such a surface — see ``mesonSource`` recipe's
##     parallel deferral.
##
## v1 of THIS recipe therefore registers fetch + versions + executable
## artifact ONLY, and ships zero flag blocks on every channel. The
## smoke test pins the registry round-trip + the four-channel empty
## state so a future convention or DSL widening can flip this recipe to
## "claimed" without re-touching it.
##
## ## Why ninja matters for the v1 desktop story
##
## ninja is the de-facto compile backend for the modern meta-build
## systems on the C / C++ desktop stack: meson's default backend
## (``meson setup --backend=ninja``) and cmake's default generator on
## Linux (``cmake -G Ninja``). Every recipe in
## ``recipes/packages/source/`` that drives ``meson compile`` or
## ``cmake --build`` consumes the ``ninja`` executable at build time.
## Direct consumers in the existing source corpus include every
## ``from-source-meson`` recipe (dbus-broker, glib2, gdk-pixbuf,
## pipewire, wireplumber, wayland, wlroots, sway, gnome-shell, mutter,
## pango, systemd, ...) and every ``from-source-cmake`` recipe (kded,
## kio, kwidgetsaddons, plasma-framework, ...). Bootstrapping ninja
## from source closes the ``uses: "ninja"`` toolchain floor those
## recipes pin without relying on the stdlib catalog's Scoop / nix
## provisioning fast path.
##
## ## sha256 strategy
##
## The fetch URL points at the upstream GitHub source-archive tarball
## ``v1.12.1.tar.gz``. The sha256 was computed by downloading the
## tarball once from the upstream URL (recorded in ``versions:``
## above):
##
##   sha256 = 821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a
##
## Tarball size = 240,483 bytes. The ``vendor/`` directory is reserved
## for a follow-up vendoring pass mirroring the existing
## ``recipes/packages/source/bash/vendor/`` precedent; v1 of the recipe
## ships the upstream URL directly so the fetch-action's argv carries
## a real, verifiable hash even before vendoring lands.
##
## ## Version choice — 1.12.1
##
## ninja releases are cut on github.com/ninja-build/ninja under tags
## of the form ``v<X>.<Y>.<Z>``. 1.12.1 is a current stable cut in the
## 1.12.x line. Anything ``>=1.10`` satisfies the meson / cmake
## consumer floor.
##
## ## Artifacts
##
## ninja exposes a single load-bearing CLI binary on disk:
##
##   * ``ninja``  — ``$PREFIX/bin/ninja``, the build-driver binary the
##                   meson / cmake compile actions invoke against the
##                   generated ``build.ninja`` manifest.
##
## ## Configurables
##
## v1 ships NO configurables and NO flag-block declarations: ninja's
## upstream bootstrap path takes no build-system flags by default
## (environment-variable overrides like ``CXX_FOR_BUILD`` /
## ``CFLAGS_FOR_BUILD`` are nixpkgs-specific and not yet in the v1
## scope), and a future ``from-source-python-bootstrap`` convention
## (or ``build: shell ...`` widening) will lower the recipe into a
## bootstrap action without needing a flag channel.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package ninjaSource:
  ## From-source ninja — M9.N Batch C build-tool slice.
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
    ## github.com source-archive URL; ``sourceRepository`` points at
    ## the canonical project tree.
    "1.12.1":
      sourceRevision = "v1.12.1"
      sourceUrl = "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz"
      sourceRepository = "https://github.com/ninja-build/ninja"

  fetch:
    ## Live upstream URL. The vendor/ directory is reserved for a
    ## follow-up vendoring pass. v1 of this recipe ships the upstream
    ## URL directly because the ninja source archive is hosted on a
    ## stable GitHub tag endpoint.
    ##
    ## sha256 was computed by downloading the tarball once from this
    ## URL (240,483 bytes).
    url: "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz"
    sha256: "821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a"
    extractStrip: 1

  nativeBuildDeps:
    ## gcc is the host C++ toolchain — ninja is C++14 with no external
    ## runtime dependencies beyond the system libstdc++.
    "gcc >=11"

  buildDeps:
    ## python3 drives the ``configure.py --bootstrap`` step that
    ## compiles ninja's C++ sources into the self-hosting binary.
    "python >=3.8"

  executable ninja:
    ## ``$PREFIX/bin/ninja`` — the build-driver binary the meson /
    ## cmake compile actions invoke against the generated
    ## ``build.ninja`` manifest. Consumed by every C / C++ recipe in
    ## ``recipes/packages/source/`` that drives meson or cmake
    ## (dbus-broker, glib2, kded, kio, plasma-framework, ...).
    ##
    ## M9.N Batch C.1 — bootstrap body via the new ``shell()`` action
    ## surface on ``build:`` blocks. The new ``from-source-custom``
    ## convention claims this recipe (no flag channels declared, two
    ## shell actions registered) and emits one ``BuildActionDef`` per
    ## shell line. ``$extracted`` resolves to ``<projectRoot>/src/``;
    ## ``$out`` resolves to
    ## ``<projectRoot>/.repro/build/from-source-custom/ninjaSource/``.
    build:
      # Bootstrap ninja's C++ sources into the self-hosting binary at
      # the source root. ``cd $extracted`` is added by the convention's
      # script-composition step so this shell runs in the extracted
      # source tree.
      shell "python3 configure.py --bootstrap"
      # Install the resulting binary into the output bin dir where the
      # stage-copy step expects it.
      shell "mkdir -p $out/bin && install -Dm755 ninja $out/bin/ninja"

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
