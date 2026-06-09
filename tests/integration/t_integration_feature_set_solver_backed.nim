## Spec-Implementation M3 — solver-backed ``FeatureSet`` integration
## test.
##
## Asserts:
##   1. ``solverFeatureSet()`` returns a fully populated adapter.
##   2. Before any variant is declared, ``enabled`` returns ``false``
##      and ``allEnabled`` returns ``@[]`` (graceful degradation, no
##      raise).
##   3. After declaring a boolean variant and running
##      ``finalizeVariants()``, the FeatureSet reports the variant's
##      resolved truth-value through ``enabled`` and ``value``.
##   4. ``allEnabled`` lists every variant whose resolved value is
##      truthy.
##   5. A static (table-backed) FeatureSet built via
##      ``newStaticFeatureSet`` answers from the supplied table
##      verbatim, demonstrating the adapter slot is replaceable.

import std/[strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/interfaces/feature_set
import repro_dsl_stdlib/adapters/solver_feature_set

suite "Spec-Implementation M3: solver-backed FeatureSet":

  setup:
    resetVariantState()

  test "solverFeatureSet is fully populated":
    let fs = solverFeatureSet()
    validate(fs)
    check fs.name == "solver-feature-set"

  test "no variants → enabled returns false, allEnabled returns empty":
    let fs = solverFeatureSet()
    check not fs.enabled("tls")
    check fs.value("tls") == ""
    check fs.allEnabled().len == 0

  test "boolean variant resolved true → fs.enabled is true":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[bool](
      defaultValue = true,
      scopeName = "tls",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let fs = solverFeatureSet()
    check fs.enabled("tls")
    check fs.value("tls") == "true"
    let all = fs.allEnabled()
    check "tls" in all

  test "boolean variant resolved false drops from allEnabled":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[bool](
      defaultValue = false,
      scopeName = "tls",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let fs = solverFeatureSet()
    check not fs.enabled("tls")
    check fs.value("tls") == "false"
    let all = fs.allEnabled()
    check "tls" notin all

  test "static FeatureSet adapter is interchangeable":
    var t = initTable[string, string]()
    t["alpha"] = "true"
    t["beta"] = "off"
    t["gamma"] = "1"
    let fs = newStaticFeatureSet(t)
    validate(fs)
    check fs.name == "static-feature-set"
    check fs.enabled("alpha")
    check not fs.enabled("beta")
    check fs.enabled("gamma")
    check fs.value("alpha") == "true"
    check fs.value("missing") == ""
    let all = fs.allEnabled()
    check all.len == 2
    check "alpha" in all
    check "gamma" in all
