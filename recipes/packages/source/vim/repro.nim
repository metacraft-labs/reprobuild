## Source-from-tarball vim recipe — the SIXTY-FIRST real from-source
## production recipe to exercise the M9.H/I/K trio. vim is the
## de-facto Unix modal editor — ``/usr/bin/vim`` is the default
## ``EDITOR=`` on every major Linux distribution that does not pin
## emacs, the implicit interpreter every ``vipw`` / ``visudo`` /
## ``crontab -e`` invocation spawns, and the ``$VISUAL`` target every
## interactive script (``git commit``, ``EDITOR=vim git rebase -i``,
## ``EDITOR=vim systemctl edit <unit>``) defers to.
##
## ## Why vim matters for the v1 desktop story
##
## vim is the default modal editor on every Linux distribution that
## doesn't explicitly ship nano as ``/usr/bin/editor``. Concrete
## consumers:
##
##   * ``visudo`` / ``vipw`` / ``vigr`` shell directly into ``vim``
##     (or ``vi`` which is symlinked to vim on every modern distro)
##     to edit ``/etc/sudoers`` / ``/etc/passwd`` / ``/etc/group``
##     atomically.
##   * ``crontab -e`` and ``EDITOR=vim crontab -e`` shell into vim
##     to edit per-user crontabs.
##   * ``git commit`` without ``-m`` spawns ``$GIT_EDITOR`` which
##     falls back to ``$EDITOR`` which defaults to vim on most
##     distros (``vim`` if installed, ``vi`` if vim is missing).
##   * ``systemctl edit <unit>`` spawns ``$SYSTEMD_EDITOR`` which
##     defaults to ``$EDITOR`` which defaults to vim.
##   * GitHub's CLI ``gh`` and Codeberg's ``forgejo`` CLI default to
##     ``$EDITOR`` for PR-body / issue-body editing.
##
## ## sha256 strategy
##
## We vendor the upstream v9.1.1000 GitHub archive .tar.gz at
## ``recipes/packages/source/vim/vendor/vim-9.1.1000.tar.gz`` and
## reference it via a ``file://`` URL. The github.com archive URL is
## recorded as ``sourceUrl`` in the ``versions:`` block for
## documentation and future-bump purposes, but the live ``fetch:``
## block points at the vendored copy so the convention layer's emitted
## fetch action is offline-reproducible.
##
## ## Version choice — 9.1.1000 (current upstream stable)
##
## vim releases are cut on github.com under tags of the form
## ``v<X>.<Y>.<patch>``. The 9.1.x line ships patch-level releases as
## ``v9.1.<patchnumber>``; 9.1.1000 is the current stable as of mid-
## 2026. Anything ``>=9.1`` covers the vim9script language overhaul
## the modern vim plugins (vim-plug, dein.vim, packer.nvim port) use.
##
## sha256 = c8ccd457bba5563513ab3e2088ad10d62b982682af9a9278686b48202b8c7697
##  (computed locally over the vendored ``vim-9.1.1000.tar.gz``,
##  18,393,329 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Build shape
##
## The c_cpp_autotools convention (M9.K) reads both the M9.H ``fetch:``
## block and the M9.I ``configureFlags:`` block off this package's
## registries and lowers them into fetch + ``./configure`` + ``make``
## BuildActions; the per-artifact build body + install glue lands in
## M9.L; the recipe records the three executable artifacts via the
## ``executable`` blocks so the M9.K artifact registry already knows
## what binaries to expect.
##
## NOTE: vim's GitHub archive's ``configure`` script lives under
## ``src/configure`` (not at the repo root) and the top-level Makefile
## re-dispatches into ``src/`` for the actual build. The c_cpp_autotools
## convention's lowering handles this layout transparently — vim's
## upstream Makefile is autotools-aware and the convention's
## ``./configure`` invocation finds the right script via the symlink
## the top-level Makefile generates on first ``make``.
##
## ## Artifacts
##
## vim's autotools build emits three load-bearing binaries from a
## single ``./configure`` + ``make`` invocation:
##
##   * ``vim``       — ``/usr/bin/vim`` the modal editor itself; the
##                      canonical ``EDITOR=`` target on every Linux
##                      distribution.
##   * ``vimdiff``   — ``/usr/bin/vimdiff`` the side-by-side diff /
##                      merge frontend git's ``git mergetool`` defaults
##                      to (``mergetool.vimdiff``). Actually a symlink
##                      to ``vim`` that flips on diff mode at startup;
##                      M9.L's install glue distinguishes the symlink
##                      target via the ``installed-path`` postprocess.
##   * ``vimtutor``  — ``/usr/bin/vimtutor`` the shell-script frontend
##                      that drives the new-user vim tutorial. Bundled
##                      with vim's release on every major distribution.
##
## ## Configurables
##
## v1 ships NO configurables — the configure flags are hardcoded to
## the modern-desktop baseline per the task brief:
##
##   * ``--enable-gui=no``       — skip the GTK / Athena / Motif GUI
##                                  surface (vim's CLI / TTY interface
##                                  is the only one the v1 desktop
##                                  consumes; GUI vim is replaced by
##                                  gvim which is a separate package
##                                  in the corpus).
##   * ``--without-x``           — skip the libX11 link entirely (no
##                                  X11 clipboard probe at startup;
##                                  v1 desktop uses Wayland and the
##                                  clipboard is handled by wl-clipboard).
##   * ``--disable-gpm``         — skip the GPM (general-purpose-mouse)
##                                  Linux-console mouse-driver
##                                  integration (v1 desktop doesn't
##                                  use Linux-console gpm; mouse input
##                                  in modern terminal emulators comes
##                                  through xterm-mouse protocol).
##   * ``--disable-perlinterp``  — skip the embedded Perl interpreter
##                                  (heavy libperl dependency surface;
##                                  v1 plugin ecosystem prefers
##                                  vim9script + Lua).
##   * ``--disable-pythoninterp`` — skip the embedded Python interpreter
##                                   (heavy libpython dependency surface;
##                                   v1 plugin ecosystem prefers
##                                   vim9script + Lua).
##   * ``--disable-rubyinterp``  — skip the embedded Ruby interpreter
##                                  (heavy libruby dependency surface;
##                                  unused by v1 plugin ecosystem).
##   * ``--disable-luainterp``   — skip the embedded Lua interpreter
##                                  (vim 8+ ships Lua via the Neovim
##                                  compat shim but vim doesn't surface
##                                  it on the v1 desktop). NOTE: this
##                                  intentionally inverts the Neovim
##                                  precedent of bundling Lua —
##                                  Reprobuild's v1 desktop ships
##                                  Neovim separately for Lua-bound
##                                  plugins (treesitter, telescope) and
##                                  vim stays minimal.

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package vimSource:
  ## From-source vim — sixty-first M9.H/I/K production recipe. The
  ## de-facto Unix modal editor; ``/usr/bin/vim`` is the default
  ## ``EDITOR=`` on every major Linux distribution that doesn't pin
  ## emacs, and the implicit interpreter every ``visudo`` / ``vipw`` /
  ## ``crontab -e`` invocation spawns.
  ##
  ## Tier-2b c_cpp_autotools convention consumer: the convention layer
  ## reads the ``fetch:`` block (registered via ``registeredFetchSpec``)
  ## and the ``configureFlags:`` block (registered via
  ## ``registeredBuildFlags`` on the ``"configure"`` channel) and
  ## lowers them into fetch + configure BuildActions wired with the
  ## right URL + hash + flags. Three-executable artifact recipe.

  defaultToolProvisioning "path"

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## github.com archive URL so a future maintainer running
    ## ``repro update-source`` can re-fetch from upstream; the live
    ## ``fetch:`` block below points at the vendored copy for
    ## deterministic offline test reproduction.
    ##
    ## ``sourceRepository`` points at the canonical vim project on
    ## github.com.
    "9.1.1000":
      sourceRevision = "v9.1.1000"
      sourceUrl = "https://github.com/vim/vim/archive/refs/tags/v9.1.1000.tar.gz"
      sourceRepository = "https://github.com/vim/vim.git"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable; the convention layer's argv carries this URL
    ## verbatim so the engine's content-addressed cache fingerprint
    ## stays stable across rebuilds.
    ##
    ## sha256 was computed over the vendored 18,393,329-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above. vim is one of the LARGER source tarballs
    ## in the from-source corpus by raw size — the runtime/ tree
    ## (syntax/, doc/, ftplugin/, indent/, ...) accounts for ~70% of
    ## the bytes.
    url: "file:///metacraft/reprobuild/recipes/packages/source/vim/vendor/vim-9.1.1000.tar.gz"
    sha256: "c8ccd457bba5563513ab3e2088ad10d62b982682af9a9278686b48202b8c7697"
    extractStrip: 1

  uses:
    ## autoconf is REQUIRED (not just a fallback): vim's GitHub archive
    ## ships ``src/configure.ac`` with a pre-generated ``src/configure``
    ## script but the top-level Makefile re-runs ``autoconf`` whenever
    ## ``src/configure.ac`` is newer than ``src/configure`` (which is
    ## the case after extraction since the tarball's mtimes are
    ## normalised by GitHub's archive endpoint).
    "autoconf"
    ## automake provides the ``Makefile.in`` templates the
    ## ``autoconf`` pass uses.
    "automake"
    ## make is the build-system driver — the c_cpp_autotools convention's
    ## compile action invokes ``make`` after ``./configure``.
    "make"
    ## gcc is the host C toolchain — vim is C99 + GNU extensions.
    "gcc >=11"
    ## ncurses is required for the TTY frontend (terminfo lookups +
    ## the alternate-screen / cup / smkx grammar vim's redraw layer
    ## drives). With ``--without-x`` set the GUI surface is skipped
    ## but the ncurses TUI is always linked in.
    "ncurses"

  configureFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: the ``./configure`` script
    ## evaluates options left-to-right and the
    ## ``--disable-luainterp`` sentinel lives at the tail so any
    ## override (e.g. a future Lua-edition variant for treesitter
    ## bridging) can append ``--enable-luainterp`` later without
    ## re-ordering this block.
    ##
    ## ``--enable-gui=no`` skips the GTK / Athena / Motif GUI surface.
    ## ``--without-x`` skips the libX11 link entirely.
    ## ``--disable-gpm`` skips the GPM Linux-console mouse-driver.
    ## ``--disable-perlinterp`` skips the embedded Perl interpreter.
    ## ``--disable-pythoninterp`` skips the embedded Python interpreter.
    ## ``--disable-rubyinterp`` skips the embedded Ruby interpreter.
    ## ``--disable-luainterp`` skips the embedded Lua interpreter.
    "--enable-gui=no"
    "--without-x"
    "--disable-gpm"
    "--disable-perlinterp"
    "--disable-pythoninterp"
    "--disable-rubyinterp"
    "--disable-luainterp"

  executable vim:
    ## ``/usr/bin/vim`` — the modal editor itself; the canonical
    ## ``EDITOR=`` target on every Linux distribution. Spawned by
    ## ``visudo`` / ``vipw`` / ``crontab -e`` / ``git commit`` /
    ## ``systemctl edit`` whenever ``$EDITOR=vim`` (or vim is the
    ## default). v1 records the artifact only; the per-artifact build
    ## body lands in M9.L when the convention's make-spawn + install-
    ## glue closes.
    discard

  executable vimdiff:
    ## ``/usr/bin/vimdiff`` — the side-by-side diff / merge frontend
    ## git's ``git mergetool`` defaults to (``mergetool.vimdiff``).
    ## Actually a symlink to ``vim`` that flips on diff mode at startup
    ## via ``argv[0]`` inspection. The artifact entry pins the
    ## expected install-side name; M9.L's install glue distinguishes
    ## the symlink target via the ``installed-path`` postprocess. v1
    ## records the artifact only.
    discard

  executable vimtutor:
    ## ``/usr/bin/vimtutor`` — the shell-script frontend that drives
    ## the new-user vim tutorial. Bundled with vim's release on every
    ## major distribution; consumed by every first-time vim user
    ## following the ``vim`` install README. v1 records the artifact
    ## only.
    discard
