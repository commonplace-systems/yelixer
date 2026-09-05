defmodule Yelixer.Item do
  @moduledoc """
  The atomic unit of a Yjs document.

  Unwinding all high-level types (`Text`, `Array`, `YMap`,
  `XmlElement`, …) leaves a flat collection of Items. Every
  operation — insertion, deletion, ordering under concurrent edits,
  encoding, garbage collection, rendering — ultimately acts on Items.

  Each Item bundles four concerns:

    - **Identity.** A unique `id :: Yelixer.ID.t()` — a `(client,
      clock)` pair assigned at authoring time and never reused. See
      `Yelixer.ID`.
    - **Causal anchors.** `origin` and `right_origin` capture the
      item's left and right neighbors *as they existed when the item
      was created*. These anchors are immutable; later edits do not
      update them. See "Causal anchors (YATA)" below.
    - **Tree placement.** `parent` (and optional `parent_sub`) names
      the containing CRDT type — a `YArray`, a `YMap` key, etc.
    - **Content.** A tagged variant carrying the payload: text,
      binary data, a tombstone length, a nested-type pointer, etc.
      See "Content variants" below.

  ## Causal anchors (YATA)

  YATA (Yet Another Transformation Approach) is Yjs's algorithm for
  ordering concurrent insertions into a shared sequence. Each item
  records two anchors at authoring time:

    - `origin` — the item immediately to its left.
    - `right_origin` — the item immediately to its right.

  When two peers both insert after the same item `X` while
  disconnected, both record `origin = X`. The right anchor breaks
  the tie: YATA's interleave rule consults `right_origin` and,
  when that is also equal, falls back to comparing client IDs.
  Every replica applies the same rule and converges to the same
  order without coordination.

  Because anchors are historical, an item's actual neighbors in the
  rendered sequence can differ from its anchors after many concurrent
  edits.

  ## Content variants

  The `content` field is a tagged tuple:

    - `{:string, s}` — a run of text characters from a single
      client; see "Run-length" below.
    - `{:any, list}` — a list of primitives (numbers, booleans,
      strings, maps) treated as opaque JSON-shaped data.
    - `{:binary, b}` — raw bytes.
    - `{:json, list}` — yrs-compatible JSON encoding; kept separate
      from `:any` for binary-format compatibility with the Rust port.
    - `{:embed, term}` — an opaque embedded value (image reference,
      rich-text object, etc.).
    - `{:format, {key, val}}` — a formatting marker, not visible
      content; describes how adjacent text should be rendered.
    - `{:type, atom}` — marks this Item as a nested CRDT (a `YArray`,
      `YMap`, etc.). The nested type's children live elsewhere and
      point back here via their `parent`.
    - `{:doc, term}` — a sub-document reference.
    - `{:deleted, n}` — tombstone of length `n`. Content has been
      cleared; only the occupied ID range is retained. See "Deletion
      and GC" below.
    - `{:gc, n}` — garbage-collected tombstone. Structurally
      identical to `:deleted` but signals that no live item anchors
      to this slot, making it a candidate for compaction.

  ## Deletion and GC

  "Deleted" is expressed two ways, serving different purposes:

    - `deleted` (boolean) is a **fast-path flag** set at construction
      from the content variant. The renderer can skip deleted items
      without inspecting content. At runtime the flag may be set
      before the content is rewritten, so the two can briefly diverge.
    - `{:deleted, n}` / `{:gc, n}` are the **persistent forms**:
      once content is dropped, only the length it occupied remains.
      The distinction between `:deleted` and `:gc` lets encoding and
      GC paths track whether the slot is still reachable from any
      live anchor.

  ## Run-length

  `length` counts how many consecutive logical clocks an Item covers.
  Typing "abc" produces one Item with `length=3` occupying clocks
  `id.clock`, `id.clock + 1`, `id.clock + 2` — far more compact than
  one item per character.

  When a concurrent operation targets a clock in the middle of a run,
  `split/2` divides the Item at that boundary so each half can be
  handled independently.

  ## Boundaries

  - Items are elements of a sequence; the sequence lives in
    `Yelixer.BlockStore`.
  - Document-level state lives in `Yelixer.Doc`.
  - Placing a new Item into YATA order is the job of
    `Yelixer.Integrate`.
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

  # Every item has a parent: either a top-level named type registered
  # on the doc, or a nested type identified by its container Item's ID
  # (the item that carries `{:type, _}` content).
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
  Constructs an Item from its six required fields.

  `deleted` and `length` are derived, not passed:

    - `deleted` — `true` when `content` is already a tombstone
      (`{:deleted, _}` or `{:gc, _}`). Can drift from the content tag
      at runtime if an item is tombstoned before its content is
      rewritten; see "Deletion and GC" in the moduledoc.
    - `length` — clocks covered by this content; see `content_length/1`.
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
  Divides a run-length item at `offset`, returning `{left, right}`.

  When a concurrent operation must anchor at a clock inside an
  existing run, the run must be split so the boundary clock can be
  addressed independently. An item covering
  `[id.clock, id.clock + length)` becomes two items covering
  `[id.clock, id.clock + offset)` and
  `[id.clock + offset, id.clock + length)`.

  ## Field assignment

  **Left half** retains the original `id`, `origin`, `right_origin`,
  and `parent*`; only `content` and `length` shrink to the first
  `offset` clocks.

  **Right half**:

    - `id` = `(client, clock + offset)` — same client, clock advanced.
    - `origin` = `(client, clock + offset - 1)` — the last clock of
      the left half, preserving causal continuity within the run.
    - `right_origin` = the original's `right_origin` *(see below)*.
    - `content` / `length` cover the remaining clocks.

  ## Invariant: both halves inherit the original's `right_origin`

  The two halves occupy the same logical YATA position as the
  original, so they must share its anchors. The previous behavior
  (fixed in CX-2sv) set `left.right_origin = right.id`. That broke
  the invariant that a leftmost item has `right_origin = nil`:
  splitting a leftmost item produced a left half that pointed at the
  new right half instead of `nil`, severing the termination of the
  right-origin chain. On encode/decode round-trips the parent linkage
  was then lost.

  Propagating the original's `right_origin` to both halves restores
  the invariant: each half is leftmost-equivalent if the original was,
  pointing at whatever lay to the original's right (often `nil`).
  """
  def split(%__MODULE__{} = item, offset) when offset > 0 and offset < item.length do
    {left_content, right_content} = split_content(item.content, offset)
    # A surrogate-interior request clamps the content upward. IDs must use
    # that same boundary, otherwise the resulting clock ranges overlap.
    offset = content_length(left_content)

    right_id = ID.new(item.id.client, item.id.clock + offset)

    left = %{item | content: left_content, length: content_length(left_content)}

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

  # Splits a content tuple at `offset` into a head/tail pair.
  # Run-length variants (string, any, binary, json, deleted, gc) each
  # get a dedicated clause. Singleton variants (embed, format, type,
  # doc) always have length 1 and can never satisfy split/2's guard
  # `offset > 0 and offset < item.length`, so they need no clause.

  defp split_content({:string, s}, offset) do
    {left, right} = utf16_split_at(s, offset)
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

  # Returns the number of logical clocks a content value covers.
  # Used to populate `length` at construction and after `split/2`.
  # Run-length variants delegate to their natural size measure;
  # tombstone variants store the count directly; all singletons
  # (embed, format, type, doc) cover one clock.
  defp content_length({:gc, n}), do: n
  defp content_length({:string, s}), do: utf16_length(s)
  defp content_length({:any, list}), do: length(list)
  defp content_length({:binary, _}), do: 1
  defp content_length({:deleted, n}), do: n
  defp content_length({:json, list}), do: length(list)
  defp content_length(_), do: 1

  @doc false
  def clamp_offset(%__MODULE__{}, 0), do: 0

  def clamp_offset(%__MODULE__{content: {:string, s}}, offset) do
    {left, _right} = utf16_split_at(s, offset)
    utf16_length(left)
  end

  def clamp_offset(%__MODULE__{}, offset), do: offset

  # ── UTF-16 CODE UNITS ─────────────────────────────────────────────
  #
  # yjs mints one clock per UTF-16 CODE UNIT (`ContentString.getLength()`
  # returns `this.str.length`, and JS string length is code units).
  # Elixir's `String.length/1` counts GRAPHEMES. Those disagree for every
  # astral character (2 units, 1 grapheme) and for every combining
  # sequence (N units, 1 grapheme) -- so an NFD "e" + combining acute is
  # 2 clocks in yjs and 1 in the old yelixer.
  #
  # ⛔ THESE TWO FUNCTIONS MUST MOVE TOGETHER WITH split_content/2's
  # {:string, _} clause. `split/2` MEASURES with content_length/1 and
  # SLICES with split_content/2, feeding the offset from one into the
  # other. Converting only the measurer hands a UTF-16 offset to a
  # grapheme splitter -- silent corruption introduced by the fix, in the
  # exact path this change exists to repair. They share `utf16_split_at/2`
  # for that reason: one unit, one place.

  defp utf16_length(s) do
    div(byte_size(:unicode.characters_to_binary(s, :utf8, {:utf16, :little})), 2)
  end

  # Splits at a UTF-16 code unit offset.
  #
  # An offset can land BETWEEN the two halves of a surrogate pair, which
  # is a position no valid string can be cut at. We clamp UP -- the whole
  # astral character goes to the left half -- following `yrs`, which
  # resolves the same impossible boundary the same way. Clamping DOWN
  # would be equally "valid" and would disagree with yrs on every astral
  # split, so the direction is a compatibility choice, not an arbitrary one.
  defp utf16_split_at(s, offset) do
    u = :unicode.characters_to_binary(s, :utf8, {:utf16, :little})
    at = offset * 2

    case utf16_cut(u, at) do
      {:ok, pair} ->
        pair

      :surrogate ->
        {:ok, pair} = utf16_cut(u, at + 2)
        pair
    end
  end

  defp utf16_cut(u, at) do
    <<l::binary-size(at), r::binary>> = u

    with left when is_binary(left) <- :unicode.characters_to_binary(l, {:utf16, :little}, :utf8),
         right when is_binary(right) <- :unicode.characters_to_binary(r, {:utf16, :little}, :utf8) do
      {:ok, {left, right}}
    else
      _ -> :surrogate
    end
  end
end
