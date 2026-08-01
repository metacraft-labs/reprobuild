## Packaging Python module sourced from the official PyPI release.
##
## Python 3.13 no longer provides distutils, so build systems use
## packaging.version for standards-compliant version comparisons.

import repro_project_dsl

package pythonPackagingSource:
  versions:
    "26.2":
      sourceRevision = "26.2"
      sourceUrl = "https://files.pythonhosted.org/packages/d7/f1/e7a6dd94a8d4a5626c03e4e99c87f241ba9e350cd9e6d75123f992427270/packaging-26.2.tar.gz"
      sourceRepository = "https://github.com/pypa/packaging"

  fetch:
    url: "https://files.pythonhosted.org/packages/d7/f1/e7a6dd94a8d4a5626c03e4e99c87f241ba9e350cd9e6d75123f992427270/packaging-26.2.tar.gz"
    sha256: "ff452ff5a3e828ce110190feff1178bb1f2ea2281fa2075aadb987c2fb221661"
    extractStrip: 1

  nativeBuildDeps:
    discard

  executable `python-packaging`:
    build:
      shell "mkdir -p $out/bin $out/share/python-modules"
      shell "cp -a $extracted/src/packaging $out/share/python-modules/"
      shell "printf '#!/bin/sh\nMODULE_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../share/python-modules\" && pwd)\necho \"$MODULE_ROOT\"\n' > $out/bin/python-packaging"
      shell "chmod +x $out/bin/python-packaging"

  runtimeDeps:
    discard
