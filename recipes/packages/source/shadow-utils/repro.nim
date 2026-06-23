## Source-from-tarball shadow-utils recipe — closes M9.R.27 Gap 4 (G4).
##
## shadow-utils ships the canonical Linux user / group / login utilities
## (``useradd``, ``userdel``, ``usermod``, ``passwd``, ``chsh``, ``chfn``,
## ``chage``, ``groupadd``, ``groupdel``, ``groupmod``, ``newuidmap``,
## ``newgidmap``, ``login``, ``su``, ``gpasswd``, ``vipw``, ``vigr``).
## Replaces Debian's ``passwd`` + ``login`` apt packages on the ReproOS
## live ISO.
##
## ## sha256 strategy
##
## Vendored at ``recipes/packages/source/shadow-utils/vendor/shadow-4.17.4.tar.xz``.
##
## sha256 = 554801054694ff7d8a7abdf0d6ece34e2f16e111673cc01b8c9ee1278451181e
##  (computed locally over the vendored ``shadow-4.17.4.tar.xz``,
##  2,326,584 bytes; downloaded once from the upstream URL recorded
##  in ``versions:`` above).
##
## ## Version choice — 4.17.4 (current upstream stable)
##
## shadow-utils releases live at github.com/shadow-maint/shadow. 4.17.4
## is the current stable as of mid-2026; the ABI / behaviour of the
## binaries has been stable since the 4.13 cut.
##
## ## Build shape
##
## autotools (``./configure && make && make install``). The
## c_cpp_autotools convention lowers the fetch + configure + make +
## install action chain.
##
## ## Artifacts
##
## shadow-utils' autotools build emits a long list of binaries; we
## register the six most-consumed ones for the v1 live ISO:
##
##   * ``useradd``   — create a new user
##   * ``passwd``    — change password / authentication info
##   * ``chsh``      — change a user's login shell
##   * ``chfn``      — change a user's GECOS finger info
##   * ``chage``     — change password aging info
##   * ``groupadd``  — create a new group

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package shadowUtilsSource:
  ## From-source shadow-utils — closes M9.R.27 Gap 4. Tier-2b
  ## c_cpp_autotools convention consumer.

  versions:
    "4.17.4":
      sourceRevision = "4.17.4"
      sourceUrl = "https://github.com/shadow-maint/shadow/releases/download/4.17.4/shadow-4.17.4.tar.xz"
      sourceRepository = "https://github.com/shadow-maint/shadow"

  fetch:
    url: "https://github.com/shadow-maint/shadow/releases/download/4.17.4/shadow-4.17.4.tar.xz"
    sha256: "554801054694ff7d8a7abdf0d6ece34e2f16e111673cc01b8c9ee1278451181e"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    "pkg-config"
    ## gettext provides msgfmt for the per-locale catalogs.
    "gettext"

  buildDeps:
    ## libxcrypt provides the modern crypt(3) password-hashing routines
    ## shadow uses for /etc/shadow + PAM.
    "libxcrypt"
    ## pam is the authentication framework login / passwd / su consume
    ## for user authentication. Stub routes through the sibling
    ## pamSource recipe / pam stdlib stub.
    "pam"
    ## libcap is the POSIX capabilities library a few helper binaries
    ## (``newuidmap`` / ``newgidmap``) link against to manage their
    ## setuid surface.
    "libcap"
    ## libaudit ships the audit subsystem hooks shadow's helpers emit
    ## events into when present.
    "audit"
    ## libbsd provides ``readpassphrase()`` which glibc lacks. shadow's
    ## ``configure`` hard-errors with "readpassphrase() is missing,
    ## either from libc or libbsd" if neither has it.
    "libbsd"

  config:
    discard
  executable useradd:
    discard
  executable passwd:
    discard
  executable chsh:
    discard
  executable chfn:
    discard
  executable chage:
    discard
  executable groupadd:
    discard

  build:
    setCurrentOwningPackageOverride("shadowUtilsSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--with-libpam",
        "--with-libcrypt",
        "--without-selinux",
        "--without-tcb",
        "--disable-nls",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("useradd")
      discard pkg.executable("passwd")
      discard pkg.executable("chsh")
      discard pkg.executable("chfn")
      discard pkg.executable("chage")
      discard pkg.executable("groupadd")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
