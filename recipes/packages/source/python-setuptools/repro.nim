## Setuptools Python module sourced from the official PyPI release.
##
## The pure-Python package is copied into source-assembled interpreter
## bundles used by build systems that still probe or import setuptools.

import repro_project_dsl

package pythonSetuptoolsSource:
  versions:
    "80.9.0":
      sourceRevision = "80.9.0"
      sourceUrl = "https://files.pythonhosted.org/packages/source/s/setuptools/setuptools-80.9.0.tar.gz"
      sourceRepository = "https://github.com/pypa/setuptools"

  fetch:
    url: "https://files.pythonhosted.org/packages/source/s/setuptools/setuptools-80.9.0.tar.gz"
    sha256: "f36b47402ecde768dbfafc46e8e4207b4360c654f1f3bb84475f0a28628fb19c"
    extractStrip: 1

  nativeBuildDeps:
    discard

  executable `python-setuptools`:
    build:
      shell "mkdir -p $out/bin $out/share/python-modules"
      shell "cp -a $extracted/setuptools $extracted/_distutils_hack $extracted/pkg_resources $out/share/python-modules/"
      shell "printf \"import os; var = 'SETUPTOOLS_USE_DISTUTILS'; enabled = os.environ.get(var, 'local') == 'local'; enabled and __import__('_distutils_hack').add_shim();\\n\" > $out/share/python-modules/distutils-precedence.pth"
      shell "printf '#!/bin/sh\nMODULE_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../share/python-modules\" && pwd)\necho \"$MODULE_ROOT\"\n' > $out/bin/python-setuptools"
      shell "chmod +x $out/bin/python-setuptools"

  runtimeDeps:
    discard
