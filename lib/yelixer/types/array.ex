defmodule Yelixer.Types.Array do
  @moduledoc """
  Collaborative array type — ordered-list facade over a YATA sequence.

  Callers think in element indices: `insert(doc, name, 2, [a, b])`
  splices two elements at position 2. Internally, each operation
  resolves that index into a YATA *anchor pair* — `{origin,
  right_origin}`, the IDs of the left and right neighbours — and
  emits one `Yelixer.Item` per element into `Yelixer.BlockStore`.

  Public surface:

    - `insert/4` — splice a list of values at an element index.
    - `push/3` — append values to the tail (sugar over `insert/4`).
    - `delete/4` — tombstone a contiguous range of elements.
    - `to_list/2` — live elements as an Elixir list.
    - `to_json/2` — live elements as JSON-shaped data, with nested
      CRDT sub-types resolved.
    - `length/2` — live element count.

  ## Array vs. Text: same machinery, different granularity

  `Yelixer.Types.Text` and Array are both facades over a YATA
  sequence in `BlockStore`, differing only in how they pack values
  into blocks:

    - **Text** packs an entire inserted string into one block
      (`content: {:string, "hello"}`, `length: 5`), run-length
      compressing character keystrokes.
    - **Array** emits one block per element (`content: {:any,
      [value]}`, `length: 1`), so every element is independently
      addressable without splitting.

  That one-block-per-element rule makes Array's index → anchor
  translation simpler: offsets always land on block boundaries.
  Compare `find_origins/3` and `find_items_in_range/4` here with
  their `_with_split` counterparts in `Yelixer.Types.Text` — the
  suffix marks exactly the split machinery Array doesn't need.

  ## Content variants

  The canonical form is `{:any, [value]}` — Yjs's JSON-shaped tagged
  value. Sequences arriving over the wire may also contain:

    - `{:type, type_ref}` — a nested CRDT sub-type (e.g. a `YArray`
      or `YMap` embedded inside this array). The sub-type's own items
      live elsewhere in the store; this block is its addressable
      handle, with the sub-type's items pointing back via
      `parent: {:id, this_block_id}`. `to_json/2` resolves these via
      `Yelixer.Types.sub_type_to_json/2`.
    - `{:string, s}` — a single string element from a peer that
      omitted the `:any` wrapper (common in yrs). Excluded from
      `to_list/2`; included in `to_json/2`.
    - `{:embed, v}` — opaque embedded value, passed through as-is.
    - `{:json, values}` — yrs-compatible JSON encoding, kept separate
      from `:any` for binary parity with the Rust port (see
      `Yelixer.Encoding`).

  `to_list/2` only surfaces `:any` content; `to_json/2` covers all
  variants.

  ## Anchor conventions

  Array uses the same anchor-pair model as `Yelixer.Types.Text`:
  `origin` is the last clock of the left neighbour (`id.clock + len
  - 1`); `right_origin` is the first clock of the right neighbour.
  See `Yelixer.Item`'s "Why both anchors" section for the YATA
  tiebreak story. Concurrent inserts at the same index resolve
  deterministically via `Yelixer.Integrate`'s two-set conflict scan,
  identical to Text.

  ## Deletion and tombstones

  `delete/4` follows the standard YATA tombstone pattern: collect
  IDs in `[index, index + len)` via `find_items_in_range/4`, mark
  each `deleted: true` via `Yelixer.Integrate.mark_deleted/2`, and
  record the `(client, clock, length)` interval in `doc.delete_set`
  via `Yelixer.DeleteSet.insert/4`. `BlockStore.get_sequence/2`
  filters tombstones from all read paths.

  Because each element is its own block, deletion never splits —
  unlike Text's partial-run-deletion. `find_items_in_range/4`
  collects whole-block IDs by summing `item.length` (always 1 for
  canonical elements; larger for wire-arriving multi-value `:any`
  blocks, which are tombstoned whole — partial deletion of such
  blocks is a known gap).

  ## Scope

  - Wire encoding: `Yelixer.Encoding`.
  - YATA placement: `Yelixer.Integrate` (this module computes anchors
    and hands the `Item` off).
  - Block storage: `Yelixer.BlockStore`.
  - Document container: `Yelixer.Doc`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc """
  Splices `values` into `type_name`'s sequence starting at element
  index `index`.

  Folds over the list, emitting one block per element. Element `i`
  lands at sequence index `index + i` and receives its own
  `(client, clock)` ID from the doc's running clock. Anchors are
  recomputed for each step — the second element anchors after the
  first, not at the original `index`.

  Every block carries `content: {:any, [value]}` regardless of
  runtime type. To store a nested CRDT sub-type, use the dedicated
  YArray or `Yelixer.Types.YMap` insertion path — passing a sub-type
  value here stores it as opaque `:any` content, not as a linked
  sub-type.
  """
  def insert(%Doc{} = doc, type_name, index, values) when is_list(values) do
    Enum.with_index(values)
    |> Enum.reduce(doc, fn {value, i}, doc ->
      {origin, right_origin} = find_origins(doc.store, type_name, index + i)
      clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
      id = ID.new(doc.client_id, clock)
      item = Item.new(id, origin, right_origin, {:any, [value]}, {:named, type_name}, nil)
      {:ok, store} = Integrate.integrate(doc.store, item, type_name)
      %{doc | store: store}
    end)
  end

  @doc """
  Appends `values` to the tail of the array. Sugar over
  `insert(doc, type_name, length(doc, type_name), values)`.
  """
  def push(%Doc{} = doc, type_name, values) do
    current_len = length(doc, type_name)
    insert(doc, type_name, current_len, values)
  end

  @doc """
  Tombstones `len` elements starting at element index `index`.

  Collects the IDs in `[index, index + len)` via
  `find_items_in_range/4`, marks each `deleted: true` via
  `Yelixer.Integrate.mark_deleted/2`, and records the
  `(client, clock, length)` intervals in `doc.delete_set`.

  No block-splitting is needed — each element is its own length-1
  block. Wire-arriving multi-value `:any` blocks are tombstoned
  whole; partial deletion of such blocks is a known gap.
  """
  def delete(%Doc{} = doc, type_name, index, len) when len > 0 do
    items = find_items_in_range(doc.store, type_name, index, len)

    {store, delete_set} =
      Enum.reduce(items, {doc.store, doc.delete_set}, fn id, {store, ds} ->
        item = BlockStore.get(store, id)
        store = Integrate.mark_deleted(store, id)
        ds = DeleteSet.insert(ds, id.client, id.clock, item.length)
        {store, ds}
      end)

    %{doc | store: store, delete_set: delete_set}
  end

  @doc """
  Returns live elements as a flat Elixir list.

  Only `:any`-content blocks contribute; tombstones are excluded by
  `BlockStore.get_sequence/2`. Other content variants (`:type`,
  `:embed`, `:string`, `:json`) are silently dropped — use `to_json/2`
  for variant-aware output.
  """
  def to_list(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(fn %Item{content: {:any, values}} -> values end)
  end

  @doc """
  Renders live elements as JSON-shaped data, resolving nested
  sub-types recursively.

  Per-variant:

    - `:any` — each value through `Yelixer.Types.resolve_content_value/2`.
    - `:type` — sub-type resolved via `Yelixer.Types.sub_type_to_json/2`.
    - `:string` — string through `resolve_content_value/2`.
    - `:embed` — returned as-is.
    - `:json` — value list flattened in.
    - Anything else — dropped (tombstones never reach here;
      `BlockStore.get_sequence/2` excludes them upstream).
  """
  def to_json(%Doc{} = doc, type_key) do
    doc.store
    |> BlockStore.get_sequence(type_key)
    |> Enum.flat_map(&item_to_json_values(doc, &1))
  end

  defp item_to_json_values(doc, %Item{content: {:any, values}}) do
    Enum.map(values, &Yelixer.Types.resolve_content_value(doc, &1))
  end

  defp item_to_json_values(doc, %Item{content: {:type, _ref}, id: id}) do
    [Yelixer.Types.sub_type_to_json(doc, id)]
  end

  defp item_to_json_values(doc, %Item{content: {:string, s}}) do
    [Yelixer.Types.resolve_content_value(doc, s)]
  end

  defp item_to_json_values(_doc, %Item{content: {:embed, v}}), do: [v]
  defp item_to_json_values(_doc, %Item{content: {:json, values}}), do: values
  defp item_to_json_values(_doc, _item), do: []

  @doc """
  Returns the live element count.

  Sums `item.length` over the live sequence. Canonical blocks
  each contribute 1; wire-arriving multi-value `:any` blocks
  contribute their list length. Tombstones excluded by
  `BlockStore.get_sequence/2`.
  """
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # ---- Index → anchor / range translation ----
  #
  # Same shape as `Yelixer.Types.Text`'s offset-walking helpers, but
  # without split machinery. Every Array element is its own length-1
  # block, so indices always land on block boundaries. Text's
  # `find_origins_with_split/3` and `find_items_in_range_with_split/4`
  # carry the `_with_split` suffix precisely because run-length blocks
  # require splitting before they can be anchored or range-collected.

  defp find_origins(store, type_name, index) do
    seq = BlockStore.get_sequence(store, type_name)

    if index == 0 and seq == [] do
      {nil, nil}
    else
      {left_item, right_item} = find_neighbors(seq, index, 0, nil)

      origin =
        case left_item do
          nil -> nil
          %Item{id: id, length: len} -> ID.new(id.client, id.clock + len - 1)
        end

      right_origin =
        case right_item do
          nil -> nil
          %Item{id: id} -> id
        end

      {origin, right_origin}
    end
  end

  defp find_neighbors([], _index, _pos, left), do: {left, nil}

  defp find_neighbors([item | rest], index, pos, left) do
    item_end = pos + item.length

    if index <= pos do
      {left, item}
    else
      if index >= item_end do
        find_neighbors(rest, index, item_end, item)
      else
        {item, List.first(rest)}
      end
    end
  end

  defp find_items_in_range(store, type_name, index, len) do
    seq = BlockStore.get_sequence(store, type_name)
    collect_ids(seq, index, len, 0, [])
  end

  defp collect_ids(_, _, 0, _, acc), do: Enum.reverse(acc)
  defp collect_ids([], _, _, _, acc), do: Enum.reverse(acc)

  defp collect_ids([item | rest], index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        collect_ids(rest, index, remaining, item_end, acc)

      pos >= index ->
        to_take = min(item.length, remaining)
        collect_ids(rest, index, remaining - to_take, item_end, [item.id | acc])

      true ->
        to_take = min(item_end - index, remaining)
        collect_ids(rest, index, remaining - to_take, item_end, [item.id | acc])
    end
  end
end
