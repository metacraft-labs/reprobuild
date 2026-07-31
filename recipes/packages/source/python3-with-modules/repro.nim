## Source-built Python environment for build-time code generators.
##
## Mesa requires Mako during configuration and code generation. The recipe
## copies the completed source CPython prefix and adds pinned Mako and
## MarkupSafe source trees without relying on pip, wheels, or Nix packages.

import repro_project_dsl

package python3WithModulesSource:
  versions:
    "1.3.12":
      sourceRevision = "1.3.12"
      sourceUrl = "https://files.pythonhosted.org/packages/00/62/791b31e69ae182791ec67f04850f2f062716bbd205483d63a215f3e062d3/mako-1.3.12.tar.gz"
      sourceRepository = "https://github.com/sqlalchemy/mako"

  fetch:
    url: "https://files.pythonhosted.org/packages/00/62/791b31e69ae182791ec67f04850f2f062716bbd205483d63a215f3e062d3/mako-1.3.12.tar.gz"
    sha256: "9f778e93289bd410bb35daadeb4fc66d95a746f0b75777b942088b7fd7af550a"
    extractStrip: 1

  nativeBuildDeps:
    "python3 >=3.8"
    "python-markupsafe"
    "python-packaging"
    "python-setuptools"
    "python-markdown"

  executable `python3-with-modules`:
    build:
      shell "PYTHON_PREFIX=$(python3 -B -c 'import sys; print(sys.prefix)'); mkdir -p $out; chmod -R u+w $out; cp -a \"$PYTHON_PREFIX\"/. $out/; chmod -R u+w $out"
      shell "PYTHON_VERSION=$(python3 -B -c 'import sys; print(\"%d.%d\" % sys.version_info[:2])'); MODULE_ROOT=$out/lib/python$PYTHON_VERSION/site-packages; mkdir -p \"$MODULE_ROOT\"; cp -a $extracted/mako \"$MODULE_ROOT/\"; MARKUPSAFE_ROOT=$(python-markupsafe); cp -a \"$MARKUPSAFE_ROOT/markupsafe\" \"$MODULE_ROOT/\"; PACKAGING_ROOT=$(python-packaging); cp -a \"$PACKAGING_ROOT/packaging\" \"$MODULE_ROOT/\""
      shell "PYTHON_VERSION=$(python3 -B -c 'import sys; print(\"%d.%d\" % sys.version_info[:2])'); MODULE_ROOT=$out/lib/python$PYTHON_VERSION/site-packages; SETUPTOOLS_ROOT=$(python-setuptools); cp -a \"$SETUPTOOLS_ROOT/setuptools\" \"$SETUPTOOLS_ROOT/_distutils_hack\" \"$SETUPTOOLS_ROOT/pkg_resources\" \"$SETUPTOOLS_ROOT/distutils-precedence.pth\" \"$MODULE_ROOT/\"; MARKDOWN_ROOT=$(python-markdown); cp -a \"$MARKDOWN_ROOT/markdown\" \"$MODULE_ROOT/\""
      shell "ln -sf python3 $out/bin/python3-with-modules"

  runtimeDeps:
    discard
