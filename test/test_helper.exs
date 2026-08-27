ExUnit.start()

# The :divergence population is RED BY DESIGN. It pins measured yelixer/yjs
# parity bugs that are not yet fixed, so it must never enter the default
# suite's count -- a suite that is red for known-and-accepted reasons stops
# being a gate, which is the exact defect the divergence job exists to
# measure. Run it deliberately:
#
#   mix test --include divergence test/yelixer/divergence_clock_test.exs
#
# CI asserts its RED count separately. When a case retires (goes green), the
# count must be restated explicitly -- a divergence that silently starts
# passing is itself a signal, and only a stated count can see it.
ExUnit.configure(exclude: [:divergence])

Code.require_file("support/file_rm_rf_guard.exs", __DIR__)
Code.require_file("support/divergence_helpers.exs", __DIR__)
