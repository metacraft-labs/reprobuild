## ct_test_runner_install — reprobuild-side wiring for the in-process
## ct-test ``TestRunner`` adapter.
##
## This is the *consumer-side* half of the M3/M4 adapter split. The
## adapter library (``ct_test_runner_adapter``, in the
## ``reprobuild-ct-test-runner`` repo) depends only on the engine-free
## ``repro_test_adapters`` contract and *constructs* a ``TestRunner``;
## installing that value into the active build context needs
## ``setTestRunner`` from the reprobuild engine, so the engine-coupled
## install lives here rather than in the adapter — that is what keeps the
## adapter from depending on the reprobuild engine (and keeps reprobuild's
## own project from forming a dependency cycle through the adapter).
##
## A reprobuild project wires the adapter from inside its ``build:`` block
## with ``installCtTestRunner(currentBuildContext())``.

import repro_dsl_stdlib/active_context
export active_context

import ct_test_runner_adapter
export ct_test_runner_adapter

proc installCtTestRunner*(ctx: BuildContext) =
  ## Install the in-process ct-test ``TestRunner`` adapter onto ``ctx``,
  ## replacing the stdlib's ``defaultTestRunner`` so RUN/LIST/ENUMERATE
  ## go through the test binary's ``--run`` / ``--list-json`` / ``--list``
  ## protocol. Reprobuild projects call this from inside their ``build:``
  ## block with ``installCtTestRunner(currentBuildContext())``.
  ctx.setTestRunner(ctTestRunner())
