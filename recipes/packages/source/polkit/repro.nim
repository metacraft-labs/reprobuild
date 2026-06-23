## Source-from-tarball polkit recipe — closes M9.R.26 Gap 3.
##
## polkit is the authorization framework GNOME/KDE/Plasma use to
## elevate privileges for system actions (mounting drives, changing
## network settings, etc.) from an unprivileged session. The live ISO
## ships polkitd + pkexec + polkit-agent-helper-1; without them the
## DEs can't elevate via the policy framework and the installer
## wizard can't pkexec into disk-format operations.
##
## ## sha256 strategy
##
## Vendored at ``recipes/packages/source/polkit/vendor/polkit-124.tar.gz``.
##
## sha256 = 72457d96a0538fd03a3ca96a6bf9b7faf82184d4d67c793eb759168e4fd49e20
##  (computed over the 757,829-byte tarball).
##
## ## Version choice — 124 (current stable)
##
## polkit's modern home is github.com/polkit-org/polkit. v124 is the
## current stable; the project also moved its build to meson + duktape
## by default (the legacy mozjs path is opt-in via -Djs_engine=mozjs).
##
## ## Build shape
##
## meson + ninja + duktape-as-JS-engine. The c_cpp_meson convention
## lowers the fetch + meson setup + ninja + install chain.
##
## ## Artifacts
##
## polkit's build emits the polkit daemon + helper binaries + the
## libpolkit-gobject-1 / libpolkit-agent-1 .so libraries:
##
##   * ``polkitd`` — the authorization daemon (runs as the polkitd
##                    system user; consumes /usr/share/polkit-1/actions/
##                    XML policy definitions).
##   * ``pkexec``  — the setuid-root command-line helper that elevates
##                    a single program invocation.
##   * ``polkit-agent-helper-1`` — the setuid PAM authentication
##                                  helper the desktop polkit agents
##                                  use to verify the operator's
##                                  password.
##   * ``libpolkit-gobject-1.so`` — the client-side library every
##                                   PolicyKit-consuming GNOME / KDE
##                                   binary links against.
##   * ``libpolkit-agent-1.so``   — the server-side library polkit
##                                   agents (gnome-shell, plasma's
##                                   polkit-kde-agent) link against.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package polkitSource:
  ## From-source polkit — closes M9.R.26 Gap 3. Tier-2b c_cpp_meson
  ## convention consumer.

  versions:
    "124":
      sourceRevision = "124"
      sourceUrl = "https://github.com/polkit-org/polkit/archive/refs/tags/124.tar.gz"
      sourceRepository = "https://github.com/polkit-org/polkit"

  fetch:
    url: "https://github.com/polkit-org/polkit/archive/refs/tags/124.tar.gz"
    sha256: "72457d96a0538fd03a3ca96a6bf9b7faf82184d4d67c793eb759168e4fd49e20"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    ## meson's gnome module invokes glib-mkenums + glib-compile-resources
    ## at configure time.
    "glib2"

  buildDeps:
    ## glib2 + gio supply the GMainLoop + GDBus the polkit daemon's
    ## D-Bus server uses. The sibling glib2Source recipe vendors 2.82.5.
    "glib2 >=2.62"
    ## expat is the XML parser polkit uses to load the per-action
    ## policy files from /usr/share/polkit-1/actions/. The sibling
    ## expatSource recipe vendors 2.7.0.
    "expat >=2.4"
    ## duktape is the JavaScript engine that evaluates the
    ## /etc/polkit-1/rules.d/*.rules per-action authorization
    ## scripts. The sibling duktapeSource recipe vendors 2.7.0
    ## (M9.R.26.3 companion).
    "duktape >=2.2"
    ## pam supplies libpam.so, consumed by polkit-agent-helper-1 for
    ## authentication. The sibling pamSource recipe vendors via the
    ## stdlib stub when needed.
    "pam"

  config:
    discard
  executable polkitd:
    discard

  executable pkexec:
    discard

  executable polkitAgentHelper1:
    discard

  library libPolkitGobject1:
    discard

  library libPolkitAgent1:
    discard

  build:
    setCurrentOwningPackageOverride("polkitSource")
    try:
      let opts = @[
        # Use duktape as the JS engine (the v1 default per upstream;
        # mozjs is a much heavier dep chain).
        "js_engine=duktape",
        # Session tracking via libsystemd-login (the sibling systemd
        # recipe ships the .pc); ConsoleKit is the legacy fallback.
        "session_tracking=libsystemd-login",
        # PAM is the authentication framework.
        "authfw=pam",
        # Drop optional surfaces we don't need at runtime.
        "examples=false",
        "tests=false",
        "introspection=false",
        "gtk_doc=false",
        "man=false",
        # Don't ship the polkitd user creation hook; the installer
        # runs systemd-sysusers against a hand-written
        # sysusers.d/polkit.conf.
        "polkitd_user=polkitd",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("polkitd")
      discard pkg.executable("pkexec")
      discard pkg.executable("polkitAgentHelper1")
      discard pkg.library("libPolkitGobject1")
      discard pkg.library("libPolkitAgent1")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
