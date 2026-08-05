defmodule Yelixer.Types.Text do
  @moduledoc """
  Collaborative text type — a character-stream view over a YATA sequence.

  This module is the public facade for a named text field inside a
  `Yelixer.Doc`. Callers work in character offsets:
  `insert(doc, name, 5, "hello")` means "insert 'hello' starting at
  position 5." Internally, every call translates that offset into a
  YATA anchor pair (`origin`, `right_origin`) and writes one or more
  `Yelixer.Item`s into the doc's `Yelixer.BlockStore`.

  Public surface:

    - `insert/4` — splice a string at a character offset.
    - `delete/4` — remove a character range.
    - `to_string/2` — render the live text as a single Elixir string.
    - `length/2` — character count of the live text.

  This module handles plain text only. Formatting marks, embedded
  objects, and change observers would emit different content variants
  (`:format`, `:embed`) into the same sequence — those belong to
  higher-level types.

  ## Run-length encoding

  One `insert` call produces **one** Item regardless of string length:
  `content: {:string, "hello"}`, `length: 5`. The block store holds
  one entry per contiguous run; the rendered text is the join of all
  live `:string` blocks. Downstream code — `Yelixer.BlockStore`'s
  offset lookups, `Yelixer.Encoding`'s wire format, and
  `Yelixer.Item.split/2` — all depend on this representation and may
  need to split a block before operating on its interior.

  ## Character offset → YATA anchor

  YATA insertion is anchored, not indexed: a new item records the
  item to its left (`origin`) and the item to its right
  (`right_origin`) at write time, so concurrent inserts at the same
  position resolve deterministically without re-indexing.

  `find_origins_with_split/3` walks the sequence, summing block
  lengths, to locate the boundary at offset `i`:

    - If `i` falls between two existing blocks, those blocks are the
      anchors.
    - If `i` falls inside a multi-character run, that block is split
      at `i` via `BlockStore.split_block/3`, and the resulting left
      and right halves become the anchors.

  For a multi-character left block, `origin` points at the **last**
  clock of the block (`id.clock + length - 1`) — the convention
  defined in `Yelixer.Item`. `right_origin` points at the **first**
  clock of the right block (its `id`). See `Yelixer.Item`'s
  "Why both anchors" section.

  ## Deletion and tombstones

  Deleted items are *tombstoned* — their `deleted` flag is set to
  `true` and their content is preserved in place rather than removed.
  This lets peers apply the same deletion even after receiving it out
  of order, and allows GC to clean up later (see `Yelixer.Doc.gc/1`).

  `delete/4` works in two steps:

    1. Walk the sequence, splitting blocks at the start and end of the
       target range so the deletion covers only whole blocks.
    2. For each block in the range, call
       `Yelixer.Integrate.mark_deleted/2` to set the flag, and record
       the `(client, clock, length)` interval in `doc.delete_set` via
       `Yelixer.DeleteSet.insert/4`.

  `to_string/2` and `length/2` call `BlockStore.get_sequence/2`,
  which filters tombstones out before returning — neither function
  checks `deleted` directly.

  ## Codepoints, not graphemes

  All offsets count Unicode **codepoints** — what `String.length/1`
  counts in Elixir — not grapheme clusters. A flag emoji or a
  skin-tone modifier sequence spans multiple codepoints and therefore
  multiple positions. This matches the behavior of Y.js and yrs, so
  documents round-trip correctly across peers. Callers that need
  grapheme-level offsets must convert before calling this API.

  ## What this module is not

  - Wire encoding: see `Yelixer.Encoding`.
  - YATA placement: see `Yelixer.Integrate`. This module computes
    anchors and hands the item off; Integrate does the ordering.
  - Block storage: see `Yelixer.BlockStore`.
  - Document container: see `Yelixer.Doc`. This module is one of
    several type facades that operate on a `%Doc{}`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, Integrate}

  @doc """
  Inserts `text` into `type_name`'s sequence at character offset
  `index`.

    1. Resolve `index` to a YATA anchor pair (`origin`, `right_origin`)
       via `find_origins_with_split/3`, splitting a run-length block if
       `index` falls in its interior.
    2. Read the caller's current clock via `Yelixer.Doc.mint_clock/1`
       — this becomes the new Item's starting clock. (Centralizes what
       used to be an inline `StateVector.get(BlockStore.state_vector(store),
       doc.client_id)` read; see that function's moduledoc for the
       `clock_floor` continuation mechanism it also serves.)
    3. Build one Item with `content: {:string, text}`. The entire
       insertion is one block regardless of length.
    4. Pass the Item to `Yelixer.Integrate.integrate/3` for YATA
       ordering and block-store insertion.
    5. Return the updated `%Doc{}`.

  Guards against empty `text` — the function is a no-op in that case.
  """
  def insert(%Doc{} = doc, type_name, index, text) when is_binary(text) and byte_size(text) > 0 do
    {store, origin, right_origin} = find_origins_with_split(doc.store, type_name, index)
    clock = Doc.mint_clock(%{doc | store: store})
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, origin, right_origin, {:string, text}, {:named, type_name}, nil)
    {:ok, store} = Integrate.integrate(store, item, type_name)
    %{doc | store: store}
  end

  def insert(%Doc{} = doc, _type_name, _index, <<>>) do
    doc
  end

  @doc """
  Tombstones `len` characters starting at character offset `index`.

  Collects the IDs covering `[index, index + len)`, splitting blocks
  at the start and end of the range so every target is a whole block.
  Each collected ID is flagged `deleted: true` via
  `Yelixer.Integrate.mark_deleted/2`; the `(client, clock, length)`
  interval is recorded in `doc.delete_set` via
  `Yelixer.DeleteSet.insert/4`.

  Content is kept on tombstoned blocks until GC runs (see
  `Yelixer.Doc.gc/1`). `to_string/2` and `length/2` already exclude
  tombstoned items via `BlockStore.get_sequence/2`.
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
  Renders the live text of `type_name` as an Elixir string.

  Joins the `:string` content of every non-tombstoned block in
  document order. `BlockStore.get_sequence/2` handles tombstone
  filtering; non-`:string` blocks (embeds, sub-types) are skipped
  here because they contribute no characters.
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
  Returns the codepoint count of the live text.

  Each block's `length` field is set to its codepoint count at
  construction by `Yelixer.Item.new/6`. Summing live blocks gives the
  total.

  Counts all live *plain-sequence* blocks, not just `:string` ones —
  embeds and sub-types contribute length but no characters. Y.Map
  keyed items sharing this name (`parent_sub != nil`) are excluded:
  they live in the map's key-space, not the text's positional
  sequence, so they must not contribute to offsets (see
  `plain_sequence/2`). In a pure-text sequence this equals
  `String.length(to_string(doc, name))`.
  """
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> plain_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # ---- Offset → anchor / range translation ----
  #
  # Both helpers walk the sequence summing block lengths until the
  # running total reaches the caller's index. When the index falls
  # inside a run-length block, they split that block via
  # `BlockStore.split_block/3` before proceeding — hence the
  # `_with_split` suffix.
  #
  # `find_origins_with_split/3` returns a left/right anchor pair for
  # a single insertion point. `find_items_in_range_with_split/4`
  # returns the list of whole-block IDs that cover a deletion range.

  # Filters a named type's block sequence down to the members of the
  # PLAIN (Text) sequence, excluding Y.Map keyed items.
  #
  # A named type can hold a mixed sequence: Y.Map keyed items
  # (`parent_sub != nil`) alongside plain Text items
  # (`parent_sub == nil`), left behind by migration residue (a
  # per-field -> single-blob schema change stranding a key item under
  # a name that a later Text also writes to). Text's positional model
  # — insert/delete offsets, YATA origin/right_origin anchors — is
  # defined over the plain sequence only. A keyed item is not a
  # member of that sequence; it lives in the map's key-space and
  # merely happens to share a name. Anchoring a Text insert's
  # origin/right_origin across that boundary lets
  # `Yelixer.Encoding.resolve_parent/2` misread positional adjacency
  # as key ownership on decode, silently discarding the text (Y.Map
  # rightmost-wins). An insert whose only live neighbour is a keyed
  # item must therefore see no neighbour at all and encode
  # `origin=nil`/`right_origin=nil` — exactly what canonical yjs
  # would author, since yjs keeps `_map` and `_start` structurally
  # separate and this situation cannot arise there.
  #
  # Filtered on `parent_sub != nil`, NOT on content type: embeds and
  # sub-types have `parent_sub == nil`, are legitimate plain-sequence
  # members, and must remain anchorable.
  defp plain_sequence(store, type_name) do
    store
    |> BlockStore.get_sequence(type_name)
    |> Enum.filter(fn %Item{parent_sub: parent_sub} -> is_nil(parent_sub) end)
  end

  defp find_origins_with_split(store, type_name, index) do
    seq = plain_sequence(store, type_name)

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
        # Index lands inside this block — split it at the boundary
        offset = index - pos
        split_clock = item.id.clock + offset
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        left_after_split = BlockStore.get(store, item.id)
        {store, left_after_split, right}
    end
  end

  # Collect whole-block IDs covering [index, index+len), splitting at range boundaries.
  defp find_items_in_range_with_split(store, type_name, index, len) do
    seq = plain_sequence(store, type_name)
    do_collect_ids(store, seq, type_name, index, len, 0, [])
  end

  defp do_collect_ids(store, _, _, _, 0, _, acc), do: {store, Enum.reverse(acc)}
  defp do_collect_ids(store, [], _, _, _, _, acc), do: {store, Enum.reverse(acc)}

  defp do_collect_ids(store, [item | rest], type_name, index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        # Block ends before the range starts — skip it.
        do_collect_ids(store, rest, type_name, index, remaining, item_end, acc)

      pos >= index and item.length <= remaining ->
        # Block is entirely inside the range — collect it.
        do_collect_ids(store, rest, type_name, index, remaining - item.length, item_end, [
          item.id | acc
        ])

      pos >= index ->
        # Block starts inside the range but extends past its end.
        # Split at the end boundary, then collect the left piece.
        split_clock = item.id.clock + remaining
        {store, _right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)
        {store, Enum.reverse([item.id | acc])}

      true ->
        # Block straddles the start of the range — split at the start boundary.
        split_clock = item.id.clock + (index - pos)
        {store, right} = BlockStore.split_block(store, ID.new(item.id.client, split_clock), type_name)

        if right.length <= remaining do
          # The right piece fits entirely in the range — re-walk from the top.
          new_seq = BlockStore.get_sequence(store, type_name)
          do_collect_ids(store, new_seq, type_name, index, remaining, 0, acc)
        else
          # The right piece also extends past the range end — split it too.
          split_end = right.id.clock + remaining
          {store, _} = BlockStore.split_block(store, ID.new(right.id.client, split_end), type_name)
          {store, [right.id]}
        end
    end
  end
end
