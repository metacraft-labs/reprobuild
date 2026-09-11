## ``bsdtar`` — libarchive's tar, and the only archiver that can WRITE
## an mtree.
##
## Not a duplicate of ``packages/tar.nim``. GNU tar and libarchive's tar
## overlap on the tar format and diverge on everything this package
## exists for: ``--format=mtree`` is libarchive's, and so are the
## ``--options=`` keyword set that selects which mtree fields are
## emitted and the ``--uid``/``--gid``/``--uname``/``--gname``/
## ``--mtime`` writer overrides that make the emitted fields a function
## of the graph rather than of the building host's filesystem.
##
## ## Why the Arch producer needs it
##
## M1's N15. An Arch package without a ``.MTREE`` member does not fail
## ``pacman -Qkk``; it SILENTLY VERIFIES NOTHING — ``pacman -Qkk``
## answers ``reprobuild: no mtree file`` and exits 0. The package is
## still valid and still installs, but the file-property verification a
## user believes they ran did not happen. Shipping the member is what
## turns that check into one that can fail.
##
## ## Provisioning-only, no ``executable`` block
##
## The Arch producer drives it from a ``sh`` script rather than through
## a typed CLI, for one reason that is specific to mtree: the member
## list has to be SORTED before it is handed over. libarchive's tar has
## no ``--sort=name`` (GNU tar's is a GNU extension), so recursing into
## a directory would record members in readdir order and the emitted
## mtree would differ between two builds of one tree. The producer
## therefore builds the list with ``find | sort`` and passes it with
## ``-T``/``-n``, which is a pipeline of three tools rather than one
## typed call. See ``packaging/producers/arch.nim``'s ``mtreeScript``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package bsdtar:
  provisioning:
    nixPackage "nixpkgs#libarchive", executablePath = "bin/bsdtar",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
