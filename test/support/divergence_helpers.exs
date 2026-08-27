defmodule Yelixer.Test.DivergenceHelpers do
  @moduledoc """
  Shared anti-vacuity gate for the `:divergence` instrument population.

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
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Flunks LOUDLY (with "VACUOUS" in the message) when `oracle_val` and
  `yelixer_val` are equal — i.e. when a case labelled as exercising a
  measured divergence did not actually diverge at this (fixture, offset).

  An arm expected to diverge that does NOT must fail as vacuous, not
  silently pass as if it were a real conformance result — an arm that
  cannot diverge is not coverage, and it looks exactly like coverage in a
  green count. `label` must be present at every call site so a failure is
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
