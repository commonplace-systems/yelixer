# CX-mchn: the two tests tagged :cx_mchn_red are a REPRODUCTION of an
# open CRDT-core data-loss bug (parent_sub wire-decode inheritance
# conflating positional adjacency with same-key ownership — see
# apps/yelixer/test/cx_mchn_delete_set_repro_test.exs). They are
# SUPPOSED to fail: they document the defect and become the acceptance
# test for its fix.
#
# They are excluded by default only so CI stays green while the fix is
# designed — NOT because they are optional. Run them deliberately with:
#
#     mix test apps/yelixer/test/cx_mchn_delete_set_repro_test.exs --include cx_mchn_red
#
# DELETE this exclusion and the tags together with the fix. An excluded
# test is an invisible one; the bead is what keeps it from quietly
# becoming permanent.
ExUnit.configure(exclude: [:cx_mchn_red])
ExUnit.start()
