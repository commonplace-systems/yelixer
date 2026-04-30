defmodule Yelixer.Item do
  @moduledoc """
  The atomic unit of a Yjs document.

  A Yjs document, after all the high-level types (`Text`, `Array`,
  `YMap`, `XmlElement`, …) are unwound, is a collection of Items —
  each carrying a chunk of content along with the metadata needed to
  position it relative to other items. Insertion, deletion, ordering
  under concurrent edits, encoding, garbage collection, and rendering
  all operate on Items.

  An Item ties four concerns together:

    - **Identity.** Every item has an `id :: Yelixer.ID.t()` — a
      `(client, clock)` pair that names it forever. See `Yelixer.ID`.
    - **Causal anchors (YATA).** `origin` and `right_origin` record
      the item's left and right neighbors *at the moment it was
      authored*. They are stable references; they do not update when
      neighbors change. See "Why both anchors" below.
    - **Tree placement.** `parent` (and optional `parent_sub`) places
      the item inside a containing CRDT type — a list element in a
      `YArray`, a value under a key in a `YMap`, etc.
    - **Content.** A single tagged variant carrying the actual data —
      run-length-encoded text, an embedded value, a tombstone marker,
      a sub-type pointer, and so on. See "Content variants" below.

  ## Why both anchors (the YATA model)

  Yjs uses YATA (Yet Another Transformation Approach) for ordering
  concurrent insertions. When Alice and Bob both insert immediately
  after item `X` while disconnected, both items record `origin = X`.
  That alone is not enough to pick a stable order between them. YATA
  resolves this by also recording `right_origin` — the item that was
  to the immediate right at authoring time — and applying a
  deterministic interleave rule (compare client IDs as a tiebreaker
  when origins agree). Both replicas independently arrive at the same
  final order.

  The anchors are *historical*: they record where the item was placed
  originally, not where it sits now. After enough concurrent edits the
  item's actual neighbors in the rendered list can be entirely
  different items.

  ## Content variants

  The `content` field is a tagged tuple:

    - `{:string, s}` — a run of text. One Item can hold many
      consecutive characters from the same client; see "length and
      run-length" below.
    - `{:any, list}` — a list of primitive values (numbers, booleans,
      strings, lists, maps treated as JSON-shaped data).
    - `{:binary, b}` — raw bytes.
    - `{:deleted, n}` — tombstone of length `n`. The item still
      occupies its ID slot but its prior content has been replaced
      with a length marker. See "Tombstones and `:gc`" below.
    - `{:gc, n}` — garbage-collected tombstone. Equivalent to
      `:deleted` but eligible for compaction; once a deletion is old
      enough that no live edits anchor to it, the content variant
      is rewritten from `:deleted` to `:gc` and the slot can
      eventually be collapsed.
    - `{:embed, term}` — an opaque embedded value (rich-text
      attribute, image reference, etc.).
    - `{:format, {key, val}}` — a formatting marker. Not visible
      content; describes how neighboring text should be rendered.
    - `{:type, atom}` — a sub-type marker. This Item *is* a nested
      CRDT (a YArray, YMap, etc.); the children of that nested type
      live elsewhere and reference this Item's ID via their
      `parent`.
    - `{:json, list}` — a yrs-compatible JSON encoding, kept distinct
      from `:any` for binary-format compatibility with the Rust port.
    - `{:doc, term}` — a sub-document reference.

  ## Tombstones and `:gc`

  Two fields can encode "this item is deleted": the `deleted` boolean
  and the content variant `{:deleted, n}` / `{:gc, n}`. They are not
  redundant — they describe overlapping but distinct states.

    - `deleted` is the **fast-path flag**. At construction time
      (`new/6`) it is derived from the content variant; at runtime it
      can be flipped independently when an item is tombstoned but its
      content hasn't yet been rewritten.
    - The `:deleted` / `:gc` content variant is the **persistent
      replacement** — once content is dropped, the variant records
      only the length the item used to occupy.

  Both representations exist so the renderer can short-circuit on the
  flag without inspecting the content tag, while encoding and GC
  paths can still distinguish "tombstoned but content present" from
  "fully cleared."

  ## Length and run-length

  `length` is the number of consecutive clocks an Item occupies. A
  user typing "abc" produces a single Item with `length=3` whose
  three clocks are `id.clock`, `id.clock + 1`, `id.clock + 2`. The
  whole document is represented far more compactly than one item per
  character.

  This compression is what makes `split/2` necessary: when a
  concurrent operation targets a clock in the middle of a run, the
  Item has to be broken in two so the boundary can be handled.

  ## What this module is not

  - Not a container — an Item is one element of a sequence; the
    sequence itself lives in `Yelixer.BlockStore`.
  - Not the document — see `Yelixer.Doc`.
  - Not the integrator — `Yelixer.Integrate` is what places new
    items into the YATA-ordered sequence.
  """

  alias Yelixer.ID

  @type content ::
          {:string, String.t()}
          | {:any, list()}
          | {:binary, binary()}
          | {:deleted, non_neg_integer()}
          | {:gc, non_neg_integer()}
          | {:embed, term()}
          | {:format, {String.t(), term()}}
          | {:type, atom()}
          | {:json, list()}
          | {:doc, term()}

  # `parent` always present; either a top-level named type registered
  # on the doc, or a nested type whose container is identified by an
  # Item ID (the parent item's `:type` content).
  @type parent_ref :: {:named, String.t()} | {:id, ID.t()}

  @type t :: %__MODULE__{
          id: ID.t(),
          origin: ID.t() | nil,
          right_origin: ID.t() | nil,
          content: content(),
          parent: parent_ref(),
          parent_sub: String.t() | nil,
          deleted: boolean(),
          length: non_neg_integer()
        }

  defstruct [:id, :origin, :right_origin, :content, :parent, :parent_sub, :deleted, :length]

  @doc """
  Builds an Item.

  `deleted` and `length` are derived rather than passed in:

    - `deleted` is true iff the content is already a tombstone variant
      (`:deleted` or `:gc`). Construction-time derivation; at runtime
      the flag can drift from the content tag — see the "Tombstones
      and `:gc`" section in the moduledoc.
    - `length` is the number of clocks the content covers; see
      `content_length/1` below.
  """
  def new(id, origin, right_origin, content, parent, parent_sub) do
    %__MODULE__{
      id: id,
      origin: origin,
      right_origin: right_origin,
      content: content,
      parent: parent,
      parent_sub: parent_sub,
      deleted: match?({:deleted, _}, content) or match?({:gc, _}, content),
      length: content_length(content)
    }
  end

  @doc """
  Splits a run-length item at `offset`, returning `{left, right}`.

  Required when a concurrent operation needs to anchor at a clock in
  the *middle* of an existing run. The original Item, which covered
  clocks `[id.clock, id.clock + length)`, becomes two Items covering
  `[id.clock, id.clock + offset)` and `[id.clock + offset,
  id.clock + length)` respectively.

  ## Field-by-field

  Left half:

    - keeps the original `id`
    - keeps the original `origin` (still anchored to the same left
      neighbor at authoring time)
    - keeps the original `right_origin` *(see invariant below)*
    - shrinks `content` and `length` to cover the first `offset` clocks

  Right half:

    - new `id` = `(client, clock + offset)` — same client, clock
      pushed forward
    - `origin` = `(client, clock + offset - 1)` — the *last* clock of
      the left half. Causal continuity inside the original run.
    - `right_origin` = the original's `right_origin` *(see invariant)*
    - tail `content`, with `length` adjusted

  ## Invariant: both halves share the original's `right_origin`

  Both Items conceptually occupy the same YATA position — the
  original Item before the split. They share the original's left and
  right anchors. Setting `left.right_origin = right.id` (the previous
  buggy behaviour fixed in CX-2sv) breaks the invariant that
  *leftmost sequence items have `right_origin = nil`*. With the
  buggy form, an item that was leftmost (and thus had
  `right_origin = nil`) would, after a split, have its left half
  pointing right at the new right half — destroying the leftmost
  marker. On encode/decode round-trips the parent linkage then got
  lost because the right_origin chain no longer terminated cleanly.

  Sharing the original's `right_origin` preserves the invariant: a
  leftmost-original split into two leftmost-equivalent halves, each
  still pointing at whatever was to the original's right (often
  `nil`).
  """
  def split(%__MODULE__{} = item, offset) when offset > 0 and offset < item.length do
    {left_content, right_content} = split_content(item.content, offset)

    right_id = ID.new(item.id.client, item.id.clock + offset)

    left = %{item |
      content: left_content,
      length: content_length(left_content)
    }

    right = %__MODULE__{
      id: right_id,
      # Causally anchored to the last clock of the left half.
      origin: ID.new(item.id.client, item.id.clock + offset - 1),
      # Inherits the original's right_origin (see invariant in @doc).
      right_origin: item.right_origin,
      content: right_content,
      parent: item.parent,
      parent_sub: item.parent_sub,
      deleted: item.deleted,
      length: content_length(right_content)
    }

    {left, right}
  end

  # Splitting a content tuple into a head/tail pair at `offset`. Each
  # variant that supports run-length representation (string, any,
  # binary, json, deleted, gc) gets a dedicated clause. Singleton
  # variants (embed, format, type, doc) have length 1 and would never
  # land here — split/2's guard rejects offset == 0 / offset == length.

  defp split_content({:string, s}, offset) do
    {left, right} = String.split_at(s, offset)
    {{:string, left}, {:string, right}}
  end

  defp split_content({:any, list}, offset) do
    {left, right} = Enum.split(list, offset)
    {{:any, left}, {:any, right}}
  end

  defp split_content({:deleted, n}, offset) do
    {{:deleted, offset}, {:deleted, n - offset}}
  end

  defp split_content({:gc, n}, offset) do
    {{:gc, offset}, {:gc, n - offset}}
  end

  defp split_content({:json, list}, offset) do
    {left, right} = Enum.split(list, offset)
    {{:json, left}, {:json, right}}
  end

  defp split_content({:binary, b}, offset) do
    <<left::binary-size(offset), right::binary>> = b
    {{:binary, left}, {:binary, right}}
  end

  # The number of clocks a piece of content covers. Drives the
  # `length` field at construction time and the `length` of each half
  # after a `split/2`.
  #
  # Run-length variants delegate to their natural size measure; the
  # tombstone variants store the count directly; everything else
  # (embed, format, type, doc) covers exactly one clock.
  defp content_length({:gc, n}), do: n
  defp content_length({:string, s}), do: String.length(s)
  defp content_length({:any, list}), do: length(list)
  defp content_length({:binary, b}), do: byte_size(b)
  defp content_length({:deleted, n}), do: n
  defp content_length({:json, list}), do: length(list)
  defp content_length(_), do: 1
end
