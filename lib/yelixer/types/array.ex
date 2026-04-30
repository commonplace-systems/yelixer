defmodule Yelixer.Types.Array do
  @moduledoc """
  Collaborative array type — element-list facade over a YATA sequence.

  Array is the user-facing facade for "treat this part of the
  document as an ordered list of arbitrary values." Callers think in
  element indices (`insert(doc, name, 2, [val_a, val_b])` means "splice
  these two elements in starting at position 2"); under the hood,
  every operation translates that index into a YATA anchor pair
  (`origin`, `right_origin`) and emits one or more `Yelixer.Item`s
  into the doc's `Yelixer.BlockStore`.

  Public surface:

    - `insert/4` — splice a list of values at an element index.
    - `push/3` — append values to the tail (sugar over `insert/4`).
    - `delete/4` — drop a contiguous range of elements.
    - `to_list/2` — render the live elements as an Elixir list.
    - `to_json/2` — render the live elements with nested CRDT
      sub-types resolved into plain JSON-shaped values.
    - `length/2` — element count of the live sequence.

  ## How Array differs from Text

  `Yelixer.Types.Text` and Array share the same underlying machinery
  — both are facades over a YATA sequence in `BlockStore`. The
  difference is the granularity of items:

    - **Text** packs a whole inserted string into ONE block with
      `content: {:string, "hello"}` and `length: 5`. Run-length
      compresses character keystrokes.
    - **Array** emits ONE block per element, each with `content:
      {:any, [value]}` and `length: 1`. There's no equivalent of
      run-length here — every element is anchored independently so
      it can be deleted or reordered without splitting.

  This means Array's offset → anchor translation is simpler than
  Text's: no need to split a multi-element block, because no block
  ever holds more than one element. Compare the private helpers in
  this file with their `_with_split` counterparts in
  `Yelixer.Types.Text` — Array's `find_origins/3` and
  `find_items_in_range/4` skip the split machinery entirely.

  ## Content variants in Array sequences

  Most elements carry `content: {:any, [value]}` — Yjs's
  JSON-shaped tagged value. But the sequence can also contain:

    - `{:type, type_ref}` — nested CRDT sub-types (a `YArray` inside
      a `YArray`, or a `YMap` inside a `YArray`). The actual
      sub-type's items live elsewhere; this block is just the
      addressable handle, parented elsewhere through their
      `parent: {:id, this_block_id}`. `to_json/2` resolves these
      via `Yelixer.Types.sub_type_to_json/2`.
    - `{:string, s}` — a string element from a peer that chose to
      use `:string` content (rare; mostly arrives over the wire from
      yrs implementations that compress single-string elements).
      `to_list/2` ignores them; `to_json/2` includes them.
    - `{:embed, v}` — opaque embedded value.
    - `{:json, values}` — yrs-compatible JSON encoding (kept distinct
      from `:any` for binary parity with the Rust port — see
      `Yelixer.Encoding`).

  `to_list/2` only surfaces `:any` content; `to_json/2` covers all
  variants and resolves nested sub-types recursively.

  ## Anchor conventions

  Array shares the same anchor-pair model as
  `Yelixer.Types.Text` and the rest of the YATA layer: `origin`
  points at the **last clock** of the left neighbour (irrelevant
  here since elements are length-1, but the convention is preserved
  via `id.clock + len - 1`); `right_origin` points at the **first
  clock** of the right neighbour. See `Yelixer.Item`'s "Why both
  anchors" section for the YATA tiebreak story.

  Concurrent inserts at the same index land in a deterministic
  order via `Yelixer.Integrate`'s two-set conflict scan, identical
  to Text.

  ## Deletion and tombstones

  `delete/4` follows the standard YATA tombstone pattern: collect the
  IDs in the index range via `find_items_in_range/4`, mark each one
  `deleted: true` via `Yelixer.Integrate.mark_deleted/2`, and record
  the `(client, clock, length)` interval in `doc.delete_set` via
  `Yelixer.DeleteSet.insert/4`. Tombstones are filtered out of read
  paths by `BlockStore.get_sequence/2`.

  Because every Array element is its own block, deletion never needs
  to split — unlike Text, where a partial-character-range deletion
  has to split the run first. Array's `find_items_in_range/4`
  collects whole-block IDs by walking the sequence summing
  `item.length` (always 1 for canonical Array elements; longer for
  any wire-arriving multi-value `:any` blocks).

  ## What this module is NOT

  - Not the wire format: encoding lives in `Yelixer.Encoding`.
  - Not the YATA placement algorithm: that's `Yelixer.Integrate`.
    This module computes anchors and hands the new Item off.
  - Not the storage: blocks live in `Yelixer.BlockStore`.
  - Not the document container: see `Yelixer.Doc`. This file is one
    of the type-side facades (alongside `Yelixer.Types.Text`,
    `YMap`, the XML modules) that operate on a `%Doc{}`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc """
  Inserts each of `values` into `type_name`'s sequence starting at
  element index `index`.

  Folds over the values, emitting one block per element. Element `i`
  in the input list lands at sequence index `index + i` and gets its
  own `(client, clock)` id from the doc's running clock. Anchors are
  computed fresh for each insertion — the second element anchors
  *after* the first, not at the original `index`.

  Each block carries `content: {:any, [value]}` regardless of the
  value's runtime type (number, string, list, map, etc.). Use
  `Yelixer.Types.YMap` for nested key/value structure and the YArray
  insertion path for nested arrays — passing a sub-type *value* here
  stores it as opaque `:any` content rather than as a CRDT sub-type.
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

  Walks the sequence summing block lengths, collects the IDs that
  fall in `[index, index + len)`, marks each `deleted: true` via
  `Yelixer.Integrate.mark_deleted/2`, and records the
  `(client, clock, length)` intervals in `doc.delete_set`.

  Unlike `Yelixer.Types.Text.delete/4`, no block-splitting is needed
  — each element is its own length-1 block (or a wire-arriving
  multi-value block, which we tombstone whole; partial deletion of
  multi-value `:any` blocks is not yet supported).
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
  Returns the live elements as a flat Elixir list.

  Only `:any`-content blocks contribute. Tombstones are filtered by
  `BlockStore.get_sequence/2`. Other content variants (`:type`,
  `:embed`, `:string`, `:json`) that may exist in a wire-arriving
  Array sequence are silently dropped — use `to_json/2` for a
  variant-aware render.
  """
  def to_list(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(fn %Item{content: {:any, values}} -> values end)
  end

  @doc """
  Renders the live array as JSON-shaped data, resolving nested CRDT
  sub-types recursively.

  Per-variant behaviour:

    - `:any` — values pass through `Yelixer.Types.resolve_content_value/2`
      so any nested CRDT-shaped values are unwrapped.
    - `:type` — looked up via `Yelixer.Types.sub_type_to_json/2`,
      which recurses into the sub-type's stored content.
    - `:string` — string passes through `resolve_content_value/2`.
    - `:embed` — embedded value returned as-is.
    - `:json` — value list flattened in.
    - Anything else — dropped (including tombstones, which never
      reach this far thanks to `BlockStore.get_sequence/2`).
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
  Returns the number of live elements.

  Sums `item.length` over the live sequence. For canonical Array
  blocks every element contributes 1; multi-value `:any` blocks
  arriving over the wire contribute their list length. Tombstones
  are excluded by `BlockStore.get_sequence/2`.
  """
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # ---- Offset → anchor / range translation ----
  #
  # Same shape as `Yelixer.Types.Text`'s offset-walking helpers, but
  # *without* the split machinery: every Array element is its own
  # length-1 block, so offsets always land cleanly on block
  # boundaries. Compare with Text's `find_origins_with_split/3` and
  # `find_items_in_range_with_split/4` — those suffix variants exist
  # specifically to handle Text's run-length blocks.

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
