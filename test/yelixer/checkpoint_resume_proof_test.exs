defmodule Yelixer.CheckpointResumeProofTest do
  @moduledoc """
  CHECKPOINT-SNAP-1 precondition gate: a document checkpointed with
  `Yelixer.StateCodec` at any cut point F and resumed with the same suffix
  is indistinguishable from the replica that ran the whole history.

  Per history (N >= 200 generated, plus long ones and fixed corpora):

    - A runs the whole delivery; C is an independent full replay under a
      different observer id (baseline: A and C must agree).
    - At each cut F (0, n, six random interior points, and the first point
      with pending blobs): B = restore(checkpoint(A at F)), compared to A at
      F; then B applies the same suffix and is compared to A.
    - Then A and B each make the same new local edits and two-way sync
      with a stale peer; then both receive the withheld update (heal).

  Compared at every stage: full-update bytes, state vector, delete set,
  pending blobs and bytes, rendered content of every type, the
  `snapshot_update/1` result, and the full canonical internal state.

  Anti-vacuity: the overlapping-delete corpus (cf. merkle
  `author_opener_test` "determinism (c)") yields different encode bytes for
  different admission orders; the comparisons must see that difference.
  Red arms: lossy codecs must fail the same proof on behaviour-visible
  fields.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{CheckpointHistory, DeleteSet, Doc, Encoding, StateCodec}
  alias Yelixer.Types.Text

  @moduletag timeout: 600_000

  @seeds 1..200
  @long_seeds 10_001..10_004

  # Built once per module; the red arms reuse it.
  setup_all do
    %{corpus: corpus()}
  end

  def corpus do
    Enum.map(@seeds, &CheckpointHistory.generate/1) ++
      Enum.map(@long_seeds, &CheckpointHistory.generate(&1, steps: 300)) ++
      [
        CheckpointHistory.generate(20_001, steps: 0),
        CheckpointHistory.generate(20_002, steps: 1)
      ] ++ overlapping_delete_histories()
  end

  # The merkle encoding_path_dependence recipe: two concurrent deletes over
  # one block, admitted in both orders.
  defp overlapping_delete_updates do
    base =
      Doc.new(client_id: 100) |> Text.insert("t", 0, "abcdefgh") |> Encoding.encode_update()

    {:ok, on_base} = Encoding.apply_update(Doc.new(client_id: 1), base)
    sv = Doc.state_vector(on_base)
    b = on_base |> Text.delete("t", 1, 3) |> Encoding.encode_diff(sv)
    c = on_base |> Text.delete("t", 2, 3) |> Encoding.encode_diff(sv)
    {base, b, c}
  end

  defp overlapping_delete_histories do
    {base, b, c} = overlapping_delete_updates()

    [
      %{seed: -1, delivery: [base, b, c], withheld: []},
      %{seed: -2, delivery: [base, c, b], withheld: []},
      %{seed: -3, delivery: [b, base, c], withheld: []},
      %{seed: -4, delivery: [base, b], withheld: [c]}
    ]
  end

  test "checkpoint + suffix is indistinguishable from full replay over the generated corpus",
       %{corpus: histories} do
    assert length(histories) >= 200
    results = Enum.map(histories, &CheckpointHistory.prove(&1, CheckpointHistory.real_codec()))

    mismatches = Enum.flat_map(results, & &1.mismatches)
    assert mismatches == [], "first mismatches: #{inspect(Enum.take(mismatches, 5))}"

    # Non-vacuity of the corpus itself, so a green here is about something.
    assert Enum.sum(Enum.map(results, & &1.cuts)) >= 1000
    assert Enum.sum(Enum.map(results, & &1.pending_cuts)) > 0, "no cut held pending blobs"
    assert Enum.any?(results, & &1.pending_end), "no history ended with pending"
    assert Enum.any?(results, &(&1.pending_end and &1.healed_clean)), "no heal drained pending"
    assert Enum.any?(results, & &1.floor), "no history exercised clock_floor"
    assert Enum.any?(results, & &1.namespaced), "no history exercised client_namespaces"
  end

  test "the corpus is path-dependent: other admission orders give other bytes",
       %{corpus: histories} do
    # A comparison that cannot see admission order would also pass a
    # codec that rebuilds an equivalent-but-different state. Show the
    # corpus contains histories where order changes the encoded state.
    {base, b, c} = overlapping_delete_updates()
    obs = fn updates -> CheckpointHistory.apply_all(Doc.new(client_id: 7), updates) end
    x = obs.([base, b, c])
    y = obs.([base, c, b])
    assert Encoding.encode_update(x) != Encoding.encode_update(y)
    assert Text.to_string(x, "t") == Text.to_string(y, "t")

    # Checkpointing x mid-history and resuming reproduces x, never y.
    {checkpoint, restore} = CheckpointHistory.real_codec()

    for f <- 0..3 do
      {prefix, suffix} = Enum.split([base, b, c], f)
      resumed = CheckpointHistory.apply_all(restore.(checkpoint.(obs.(prefix))), suffix)
      assert Encoding.encode_update(resumed) == Encoding.encode_update(x)
      assert Encoding.encode_update(resumed) != Encoding.encode_update(y)
    end

    # And across the generated corpus, reordering changes bytes somewhere.
    reordered =
      Enum.count(Enum.take(histories, 200), fn %{delivery: d} ->
        length(d) > 2 and
          Encoding.encode_update(obs.(d)) != Encoding.encode_update(obs.(Enum.reverse(d)))
      end)

    assert reordered > 0
  end

  # ── red arms ──────────────────────────────────────────────────────
  #
  # Each arm must fail on BEHAVIOUR: rendered content, wire bytes, state
  # vector or delete set — never only on a field that echoes the dropped
  # one (`types`, `pending`) or on internal canonical state.

  defp lossy(transform) do
    {checkpoint, restore} = CheckpointHistory.real_codec()
    {fn doc -> checkpoint.(doc) end, fn bytes -> transform.(restore.(bytes)) end}
  end

  # First mismatch over the corpus satisfying `pred`, or nil.
  defp red_arm(corpus, codec, pred) do
    Enum.find_value(corpus, fn h ->
      Enum.find(CheckpointHistory.prove(h, codec).mismatches, pred)
    end)
  end

  defp has?(fields, wanted), do: Enum.any?(fields, &(&1 in wanted))

  test "RED: a codec that drops the delete set fails the proof on behaviour", %{corpus: c} do
    pred = fn {_, _, _, fields} ->
      has?(fields, [:update | CheckpointHistory.rendered_fields()])
    end

    assert {_, _, _, _} = red_arm(c, lossy(&%{&1 | delete_set: DeleteSet.new()}), pred)
  end

  test "RED: a codec that drops pending blobs diverges once the heal arrives", %{corpus: c} do
    pred = fn {_, _, stage, fields} ->
      stage == "after heal" and has?(fields, [:update | CheckpointHistory.rendered_fields()])
    end

    assert {_, _, "after heal", _} =
             red_arm(c, lossy(&%{&1 | pending: [], pending_bytes: 0}), pred)
  end

  test "RED: a codec that drops the local type registry renders differently", %{corpus: c} do
    pred = fn {_, _, _, fields} -> has?(fields, [:text, :xml, :fragment, :rich, :nested]) end
    assert {_, _, _, _} = red_arm(c, lossy(&%{&1 | types: %{}}), pred)
  end

  test "RED: a plain Yjs full update (encode_update + apply_update) is not a sufficient codec",
       %{corpus: c} do
    # Fair variant: the statically known roots are re-registered and the
    # client id is kept. What it still loses, each shown by behaviour:
    plain =
      {fn doc -> {doc.client_id, Encoding.encode_update(doc)} end,
       fn {client_id, bytes} ->
         {:ok, doc} = Encoding.apply_update(CheckpointHistory.registered(client_id), bytes)
         doc
       end}

    # (1) pending blobs: the healed replica differs on the wire.
    assert {_, _, "after heal", _} =
             red_arm(c, plain, fn {_, _, stage, f} ->
               stage == "after heal" and has?(f, [:update, :state_vector])
             end)

    # (2) clock_floor: the replica's next local edits mint different ids.
    assert {_, _, _, _} =
             red_arm(Enum.filter(c, &(Map.get(&1, :floor, 0) > 0)), plain, fn {_, _, _, f} ->
               :next_clock in f
             end)

    # (3) client_namespaces: provenance queries answer differently.
    assert {_, _, _, _} =
             red_arm(Enum.filter(c, &Map.get(&1, :namespaced, false)), plain, fn {_, _, _, f} ->
               :provenance in f
             end)
  end

  test "the real codec's checkpoint is canonical (re-encoding a restore is byte-identical)",
       %{corpus: c} do
    {checkpoint, restore} = CheckpointHistory.real_codec()

    for %{delivery: d} = h <- Enum.take(c, 40) do
      a = CheckpointHistory.deliver(CheckpointHistory.observer(1, h), d, h)
      bytes = checkpoint.(a)
      assert checkpoint.(restore.(bytes)) == bytes
      assert {:ok, _} = StateCodec.decode(bytes, "checkpoint-proof")
    end
  end
end
