defmodule Yelixer.Types.Text do
  @moduledoc """
  Collaborative text type — string-stream view over a YATA sequence.

  Text is the user-facing facade for "treat this part of the document
  as a character stream." Callers think in character offsets
  (`insert(doc, name, 5, "hello")` means "insert 'hello' starting at
  character 5"); under the hood, every operation translates that
  offset into a YATA anchor pair (`origin`, `right_origin`) and emits
  one or more `Yelixer.Item`s into the doc's `Yelixer.BlockStore`.

  Public surface:

    - `insert/4` — splice a string into the sequence at a character
      offset.
    - `delete/4` — drop a character range from the sequence.
    - `to_string/2` — render the live (non-tombstoned) characters as
      a single Elixir string.
    - `length/2` — character count of the live sequence.

  No formatting, embeds, observers, or rich-text features in this
  module — those live higher up the stack and would emit different
  content variants (`:format`, `:embed`) into the same sequence.
  This file is the plain-text core.

  ## Run-length encoding

  A single `insert(doc, name, 5, "hello")` call emits **one** Item
  with `content: {:string, "hello"}` and `length: 5`, not five
  separate items. The block store keeps one entry per run; the
  rendered text is the concatenation of all live `:string` blocks.
  This matters everywhere downstream: `Yelixer.BlockStore`'s binary
  search lookups, `Yelixer.Encoding`'s wire format, and the
  `Yelixer.Item.split/2` machinery all assume run-length blocks
  exist and may need partitioning.

  ## The character-offset → YATA-anchor bridge

  Insertion at character offset `i` needs to anchor between two
  existing block boundaries — `origin` to the left and
  `right_origin` to the right. `find_origins_with_split/3` walks the
  sequence summing block lengths until it crosses `i`:

    - If `i` lands cleanly between two blocks, those are the anchors.
    - If `i` lands *inside* a block (a multi-char run), the block is
      split via `BlockStore.split_block/3` first so the boundary
      exists, then the new left half becomes `origin` and the new
      right half becomes `right_origin`. The fresh insertion sits
      between them, all three blocks share the same parent, and
      YATA's interleave rule resolves their order
      (`Yelixer.Integrate`).

  `origin` for a multi-char left block points at the **last clock**
  of the block (`id.clock + length - 1`) — `Yelixer.Item`'s anchor
  convention. `right_origin` points at the **first clock** of the
  right block (its `id`). See `Yelixer.Item`'s "Why both anchors"
  section.

  ## Deletion and tombstones

  `delete/4` follows the same offset-walking pattern but flags
  matching items rather than emitting new ones:

    1. Walk the sequence, splitting blocks at the start and end of
       the range so the deletion targets whole blocks.
    2. For each block in the range, set `deleted: true` via
       `Yelixer.Integrate.mark_deleted/2`, and record the
       `(client, clock, length)` interval in `doc.delete_set` via
       `Yelixer.DeleteSet.insert/4`.

  `to_string/2` and `length/2` rely on
  `Yelixer.BlockStore.get_sequence/2`, which already filters
  tombstoned items — neither function inspects `deleted` directly,
  but tombstones are nevertheless invisible because they're
  short-circuited there.

  ## Codepoints, not graphemes

  All offsets are **codepoint** offsets in the Elixir sense
  (`String.length/1`, `String.split_at/2`), not grapheme clusters.
  An emoji that spans multiple codepoints (a flag, a skin-tone
  modifier sequence) counts as more than one position. This is
  consistent with yrs and with Y.js's behaviour, so wire-level
  exchanges round-trip correctly; callers wanting grapheme-level
  semantics need a layer above this one.

  ## What this module is NOT

  - Not the wire format: encoding lives in `Yelixer.Encoding`.
  - Not the YATA placement algorithm: that's `Yelixer.Integrate`.
    This module computes anchors and hands the new Item off.
  - Not the storage: blocks live in `Yelixer.BlockStore`.
  - Not the document container: see `Yelixer.Doc`. This file is
    one of the type-side facades that operate *on* a `%Doc{}`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate, StateVector}

  @doc """
  Inserts `text` into `type_name`'s sequence at character offset
  `index`.

  Five-step pipeline:

    1. Resolve `index` to a YATA anchor pair via
       `find_origins_with_split/3`, splitting an existing run-length
       block if `index` lands in its interior.
    2. Read the current high-water clock for our `client_id` from
       `BlockStore.state_vector/1` — this becomes the new Item's
       starting clock.
    3. Build a single Item with `content: {:string, text}` and
       `length: String.length(text)`. Run-length compresses the whole
       insertion into one block.
    4. Hand off to `Yelixer.Integrate.integrate/3` for YATA placement
       and BlockStore insertion.
    5. Return the updated `%Doc{}`.

  No-op on empty `text` (caught by the guard).
  """
  def insert(%Doc{} = doc, type_name, index, text) when is_binary(text) and byte_size(text) > 0 do
    {store, origin, right_origin} = find_origins_with_split(doc.store, type_name, index)
    clock = StateVector.get(BlockStore.state_vector(store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:string, text}, {:named, type_name}, nil)
    {:ok, store} = Integrate.integrate(store, item, type_name)
    %{doc | store: store}
  end

  @doc """
  Tombstones `len` characters starting at character offset `index`.

  Walks the sequence to collect the IDs that fall in `[index, index +
  len)`, splitting blocks at the start and end of the range so the
  deletion targets whole blocks. Each collected ID is marked
  `deleted: true` via `Yelixer.Integrate.mark_deleted/2`, and the
  corresponding `(client, clock, length)` interval is recorded in
  `doc.delete_set`.

  The original content is preserved on each tombstoned block during
  the GC grace period (see `Yelixer.Doc.gc/1`). Subsequent reads via
  `to_string/2` and `length/2` already filter tombstoned items.
  """
  def delete(%Doc{} = doc, type_name, index, len) when len > 0 do
    {store, ids_to_delete} = find_items_in_range_with_split(doc.store, type_name, index, len)

    {store, delete_set} =
      Enum.reduce(ids_to_delete, {store, doc.delete_set}, fn id, {store, ds} ->
        item = BlockStore.get(store, id)
        store = Integrate.mark_deleted(store, id)
        ds = DeleteSet.insert(ds, id.client, id.clock, item.length)
        {store, ds}
      end)

    %{doc | store: store, delete_set: delete_set}
  end

  @doc """
  Renders the live text content of `type_name` as an Elixir string.

  Concatenates the `:string` content of every non-tombstoned block
  in the sequence. Tombstones are filtered by
  `BlockStore.get_sequence/2`; non-`:string` blocks (sub-types,
  embeds) are skipped here — they don't contribute character output.
  """
  def to_string(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(fn
      %Item{content: {:string, s}} -> [s]
      _ -> []
    end)
    |> Enum.join()
  end

  @doc """
  Returns the codepoint length of the live text. Each block's
  `length` field already counts codepoints (set at construction by
  `Yelixer.Item.new/6`'s `content_length/1`); summing live blocks
  produces the total.

  Note: counts non-`:string` blocks as well — every live block in
  the sequence contributes its length. For most Text-only documents
  this is identical to `String.length(to_string(doc, name))`; if
  the sequence contains embeds or sub-types, the values diverge.
  """
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # ---- Offset → anchor / range translation ----
  #
  # Both private helpers below walk the sequence summing block
  # lengths until the running offset reaches the caller's character
  # index. When the index lands in the middle of a run-length block,
  # they call `BlockStore.split_block/3` to create the boundary
  # before continuing — that's the "with_split" suffix in their names.
  #
  # `find_origins_with_split/3` returns a left/right anchor pair for
  # insertion; `find_items_in_range_with_split/4` returns a list of
  # whole-block IDs that fall in a deletion range.

  defp find_origins_with_split(store, type_name, index) do
    seq = BlockStore.get_sequence(store, type_name)

    if index == 0 and seq == [] do
      {store, nil, nil}
    else
      {store, left_item, right_item} = find_neighbors_with_split(store, seq, type_name, index)

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

      {store, origin, right_origin}
    end
  end

  defp find_neighbors_with_split(store, items, type_name, index) do
    do_find_neighbors(store, items, type_name, index, 0, nil)
  end

  defp do_find_neighbors(store, [], _type_name, _index, _pos, left) do
    {store, left, nil}
  end

  defp do_find_neighbors(store, [item | rest], type_name, index, pos, left) do
    item_end = pos + item.length

    cond do
      index <= pos ->
        {store, left, item}

      index >= item_end ->
        do_find_neighbors(store, rest, type_name, index, item_end, item)

      true ->
        # Index falls within this item — split it
        offset = index - pos
        split_clock = item.id.clock + offset
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        left_after_split = BlockStore.get(store, item.id)
        {store, left_after_split, right}
    end
  end

  # Find item IDs in a character range, splitting at boundaries as needed.
  defp find_items_in_range_with_split(store, type_name, index, len) do
    seq = BlockStore.get_sequence(store, type_name)
    do_collect_ids(store, seq, type_name, index, len, 0, [])
  end

  defp do_collect_ids(store, _, _, _, 0, _, acc), do: {store, Enum.reverse(acc)}
  defp do_collect_ids(store, [], _, _, _, _, acc), do: {store, Enum.reverse(acc)}

  defp do_collect_ids(store, [item | rest], type_name, index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        # Before the range, skip
        do_collect_ids(store, rest, type_name, index, remaining, item_end, acc)

      pos >= index and item.length <= remaining ->
        # Entire item is within range
        do_collect_ids(store, rest, type_name, index, remaining - item.length, item_end, [
          item.id | acc
        ])

      pos >= index ->
        # Item extends beyond range — split at end of deletion range
        split_clock = item.id.clock + remaining
        {store, _right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        {store, Enum.reverse([item.id | acc])}

      true ->
        # Partial overlap at start — split at start of range
        split_clock = item.id.clock + (index - pos)
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)

        if right.length <= remaining do
          # Take the whole right piece and continue
          new_seq = BlockStore.get_sequence(store, type_name)
          # Re-walk from the split point
          do_collect_ids(store, new_seq, type_name, index, remaining, 0, acc)
        else
          # Need to also split at the end
          split_end = right.id.clock + remaining
          {store, _} = BlockStore.split_block(store, ID.new(right.id.client, split_end), type_name)
          {store, [right.id]}
        end
    end
  end
end
