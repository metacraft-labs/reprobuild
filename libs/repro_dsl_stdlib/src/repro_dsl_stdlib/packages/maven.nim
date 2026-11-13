## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 3.9.16
##
## M69 (hand-edited): the ``env = "MAVEN_HOME=${prefix}"`` binding on the
## realizations below is a hand-merged M69 addition. ``MAVEN_HOME`` is the
## conventional environment variable that Maven itself, IDEs, and the
## M40 java-maven Tier 2b probe consult; it is exported by
## ``D:/metacraft/env.ps1`` at line 404 against the metacraft-dev-deps
## prefix. The harvester does NOT auto-detect this binding from the
## Scoop manifest (Scoop's ``env_set`` block carries no ``MAVEN_HOME``
## for this package), so a re-harvest emits statements without it; keep
## the binding when merging a re-harvest, or the home archive realizer
## emits no ``MAVEN_HOME`` resource.
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization manually (Maven ships on
## ``archive.apache.org/dist/maven/``, not GitHub Releases — the M7
## gh-releases harvester doesn't apply). URL pattern:
## ``apache-maven-<ver>-bin.tar.gz``; sha512 (Apache mirror's
## canonical digest) lifted from the upstream sidecar. The archive is
## ``tar.gz``; the maven tarball ships a universal cross-platform Java
## distribution under ``apache-maven-<ver>/``; the Linux launcher is
## ``bin/mvn`` (the same script the Windows realization declares as an
## extra executable; the .cmd is windows-specific). Maven is a portable
## Java app; glibc floor is whatever the underlying JDK enforces.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package maven:
  provisioning:
    tarball url = "https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.zip",
      sha512 = "ed41650d42485cfc243fad22158caf9cbb5dc408ce7a09ddb94dd42a019de929ca43065bfa450612cf12bf78b5cafa3884b96c090de326ff590448c933454af3",
      archiveType = "zip",
      executablePath = "bin/mvn.cmd",
      extraExecutable = "bin/mvn",
      version = "3.9.16",
      packageId = "maven@3.9.16",
      extractPath = "apache-maven-3.9.16",
      env = "MAVEN_HOME=${prefix}",
      os = "windows"
    tarball url = "https://archive.apache.org/dist/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.tar.gz",
      sha512 = "831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6",
      archiveType = "tar.gz",
      executablePath = "bin/mvn",
      version = "3.9.16",
      packageId = "maven@3.9.16",
      extractPath = "apache-maven-3.9.16",
      env = "MAVEN_HOME=${prefix}",
      cpu = "x86_64",
      os = "linux"
