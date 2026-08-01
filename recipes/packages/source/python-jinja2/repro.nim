## Jinja2 Python module sourced from the official PyPI release.
##
## Systemd uses Jinja2 while generating tables and documentation-derived
## source files during its Meson build. The package is pure Python and is
## copied into the assembled source-built interpreter without invoking pip.

import repro_project_dsl

package pythonJinja2Source:
  versions:
    "3.1.6":
      sourceRevision = "3.1.6"
      sourceUrl = "https://files.pythonhosted.org/packages/source/j/jinja2/jinja2-3.1.6.tar.gz"
      sourceRepository = "https://github.com/pallets/jinja"

  fetch:
    url: "https://files.pythonhosted.org/packages/source/j/jinja2/jinja2-3.1.6.tar.gz"
    sha256: "0137fb05990d35f1275a587e9aee6d56da821fc83491a0fb838183be43f66d6d"
    extractStrip: 1

  nativeBuildDeps:
    discard

  executable `python-jinja2`:
    build:
      shell "mkdir -p $out/bin $out/share/python-modules"
      shell "cp -a $extracted/src/jinja2 $out/share/python-modules/"
      shell "printf '#!/bin/sh\nMODULE_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../share/python-modules\" && pwd)\necho \"$MODULE_ROOT\"\n' > $out/bin/python-jinja2"
      shell "chmod +x $out/bin/python-jinja2"

  runtimeDeps:
    "python-markupsafe"
