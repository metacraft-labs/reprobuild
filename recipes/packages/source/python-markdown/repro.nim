## Python-Markdown module sourced from the official PyPI release.
##
## GObject Introspection uses this pure-Python package while generating
## documentation metadata embedded in GIR output.

import repro_project_dsl

package pythonMarkdownSource:
  versions:
    "3.9":
      sourceRevision = "3.9"
      sourceUrl = "https://files.pythonhosted.org/packages/source/m/markdown/markdown-3.9.tar.gz"
      sourceRepository = "https://github.com/Python-Markdown/markdown"

  fetch:
    url: "https://files.pythonhosted.org/packages/source/m/markdown/markdown-3.9.tar.gz"
    sha256: "d2900fe1782bd33bdbbd56859defef70c2e78fc46668f8eb9df3128138f2cb6a"
    extractStrip: 1

  nativeBuildDeps:
    discard

  executable `python-markdown`:
    build:
      shell "mkdir -p $out/bin $out/share/python-modules"
      shell "cp -a $extracted/markdown $out/share/python-modules/"
      shell "printf '#!/bin/sh\nMODULE_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")/../share/python-modules\" && pwd)\necho \"$MODULE_ROOT\"\n' > $out/bin/python-markdown"
      shell "chmod +x $out/bin/python-markdown"

  runtimeDeps:
    discard
