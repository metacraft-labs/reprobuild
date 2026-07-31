## MarkupSafe Python module sourced from the official PyPI release.
##
## The package is pure Python when its optional C accelerator is absent. This
## source tree is consumed by python3-with-modules while assembling the build
## interpreter used by Mesa and other code generators.

import repro_project_dsl

package pythonMarkupSafeSource:
  versions:
    "3.0.3":
      sourceRevision = "3.0.3"
      sourceUrl = "https://files.pythonhosted.org/packages/7e/99/7690b6d4034fffd95959cbe0c02de8deb3098cc577c67bb6a24fe5d7caa7/markupsafe-3.0.3.tar.gz"
      sourceRepository = "https://github.com/pallets/markupsafe"

  fetch:
    url: "https://files.pythonhosted.org/packages/7e/99/7690b6d4034fffd95959cbe0c02de8deb3098cc577c67bb6a24fe5d7caa7/markupsafe-3.0.3.tar.gz"
    sha256: "722695808f4b6457b320fdc131280796bdceb04ab50fe1795cd540799ebe1698"
    extractStrip: 1

  nativeBuildDeps:
    discard

  executable `python-markupsafe`:
    build:
      shell "mkdir -p $out/bin $out/share/python-modules"
      shell "cp -a $extracted/src/markupsafe $out/share/python-modules/"
      shell "printf '#!/bin/sh\nMODULE_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../share/python-modules\" && pwd)\necho \"$MODULE_ROOT\"\n' > $out/bin/python-markupsafe"
      shell "chmod +x $out/bin/python-markupsafe"

  runtimeDeps:
    discard
