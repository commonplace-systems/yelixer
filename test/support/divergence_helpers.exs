defmodule Yelixer.Test.DivergenceHelpers do
  @moduledoc """
  Shared vacuity CONTROL for the `:divergence` instrument population.

  Extracted from `test/yelixer/divergence_clock_test.exs` (CX-divergence)
  so the wire/content instrument (`test/yelixer/divergence_content_test.exs`,
  CX-content-divergence) can reuse the exact same gate rather than a second,
  possibly-drifted copy. Both callers wire it in via `Code.require_file/2`
  from `test/test_helper.exs`, mirroring `file_rm_rf_guard.exs`'s pattern —
  `test/support` is not on `elixirc_paths` for this project, so nothing here
  compiles unless a caller requires it explicitly.

  ⛔ Do not duplicate `assert_diverges!/3` back into either test file. One
  copy, two callers — a divergence between the copies would mean one
  instrument's vacuity guard silently drifted from the other's without
  either file's diff showing it.

  ## ⚖️ What this is for NOW, and what it must NEVER be used for again

  Both `:divergence` test files were rewritten so that each `:divergence`
  arm asserts the DESIRED (parity) outcome directly and is RED TODAY —
  see the "INVERTED ARMS" section of `divergence_clock_test.exs`'s
  moduledoc for the full ruling and why that inversion is safe only
  because `:divergence` is excluded from the default suite.

  Before that rewrite, `assert_diverges!/3` was called as a *precondition*
  inside every `:divergence` arm, before that arm's real assertion. That
  was the defect being fixed: a closed divergence could not make an arm
  PASS under that design — it only moved the failure one line earlier,
  from a mismatch assertion to a "VACUOUS" flunk here. The failure COUNT
  never changed, so this function's firing was indistinguishable from the
  clock-unit fix doing nothing.

  ⛔ **NEVER call this function as a precondition inside a `:divergence`
  arm again.** That is the exact trap this rewrite closed.

  ✅ **What it IS still for**: a SEPARATE, LABELLED vacuity CONTROL,
  exercised only by the dedicated "vacuity guard" describe block in each
  test file (deliberately-vacuous and deliberately-real inputs, asserted
  to raise / not raise respectively). In that role it still does real
  work — it is the thing that would catch an arm that stopped being able
  to fail for the WRONG reason (a fixture edit, a normalization slip, a
  drifted coordinate), as distinct from an arm whose defect genuinely
  closed. Those two failure modes must never again share an observable —
  that conflation is exactly what made the pre-inversion design silently
  blind to the fix landing.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Flunks LOUDLY (with "VACUOUS" in the message) when `oracle_val` and
  `yelixer_val` are equal.

  Used ONLY by the dedicated "vacuity guard" describe blocks in
  `divergence_clock_test.exs` and `divergence_content_test.exs` — never as
  a precondition inside a `:divergence` arm (see the moduledoc above for
  why). `label` must be present at every call site so a failure is
  self-describing without cross-referencing line numbers.
  """
  def assert_diverges!(oracle_val, yelixer_val, label) do
    if oracle_val == yelixer_val do
      flunk("""
      VACUOUS DIVERGENCE CASE: #{label}

      oracle and yelixer AGREED (#{inspect(oracle_val)}). This case is
      labelled as exercising a measured divergence but the two
      implementations did not actually disagree at this (fixture,
      offset). Either this coordinate has stopped diverging (restate
      it as a negative control with a comment explaining why) or the
      harness picked the wrong coordinate — this must not be reported
      as a passing conformance result either way.
      """)
    end

    :ok
  end
end
