defmodule Yelixer.Types do
  @moduledoc """
  Read-path routing utilities: primitive pass-through and nested
  sub-type resolution.

  No struct, no state, no GenServer. Two responsibilities:

    - **Primitives** — `resolve_content_value/2` passes strings,
      numbers, booleans, `nil`, lists, and maps through unchanged,
      giving every facade a single call site regardless of value type.
    - **Nested CRDTs** — `sub_type_to_json/2` resolves blocks whose
      content is `{:type, type_ref}` into JSON, dispatching to the
      right facade. This is where the `__sub:CLIENT:CLOCK` naming
      loop closes.

  ## Closing the `__sub:CLIENT:CLOCK` loop

  On the **write path**, inserting a nested CRDT into a YMap or
  Array causes `Yelixer.Doc` to register the sub-type in
  `doc.types` under a synthetic key `"__sub:<client>:<clock>"`
  derived from the parent block's id. The parent block itself just
  records `{:type, type_ref}` as its content. See
  `Yelixer.Doc`'s "Sub-types and the `__sub:CLIENT:CLOCK` naming"
  section, `Yelixer.Types.YMap`, and the XML modules for the write
  sites.

  On the **read path**, `sub_type_to_json/2` receives the parent
  block's id, rebuilds the same synthetic key, looks up what kind
  of sub-type was registered (`:text`, `:array`, `:map`,
  `:xml_fragment`), and calls the matching facade. The recursion
  is natural: a sub-type whose items contain further `{:type,
  type_ref}` blocks just calls back here again.

  ## Scope

  - Not a content encoder — `Yelixer.Encoding` owns the wire format.
  - Not a sub-type creator — write sites mint the synthetic names;
    this module only consumes them.
  - Not the BlockStore — reads via `BlockStore.get_sequence/2`.
  """

  @doc """
  Returns any primitive value unchanged.

  Explicit clauses for strings, numbers, booleans, `nil`, lists,
  and maps; a catch-all handles everything else. The explicit
  clauses aren't redundant — they document the JSON-shape contract:
  callers can rely on these types surviving unmodified.

  Does **not** recurse into CRDT structure. Values carrying
  `{:type, type_ref}` content are routed through
  `sub_type_to_json/2` by the calling facade before they reach
  here.
  """
  def resolve_content_value(_doc, value) when is_binary(value), do: value
  def resolve_content_value(_doc, value) when is_number(value), do: value
  def resolve_content_value(_doc, value) when is_boolean(value), do: value
  def resolve_content_value(_doc, nil), do: nil
  def resolve_content_value(_doc, value) when is_list(value), do: value
  def resolve_content_value(_doc, value) when is_map(value), do: value
  def resolve_content_value(_doc, value), do: value

  @doc """
  Resolves a nested CRDT sub-type to its JSON representation.

  Given the id of a parent Item whose content is `{:type, type_ref}`:

    1. Rebuilds the synthetic key `"__sub:<client>:<clock>"` from
       the parent id's `client` and `clock` fields.
    2. Looks up `doc.types[key]` for the kind registered at insert
       time — one of `:text`, `:array`, `:map`, `:xml_fragment`
       (the same atoms `Yelixer.Doc.get_or_create_type/3` accepts).
    3. Dispatches to the matching facade: `Text.to_string`,
       `Array.to_json`, `YMap.to_json`, or `xml_fragment_to_json/2`
       for the Yjs-v14 unified shape.
    4. Returns `nil` for unrecognized kinds.

  This is the read side of the contract whose write side lives in
  `Yelixer.Doc` (minting the name on insertion) and whose call
  sites are `Yelixer.Types.YMap` and the XML modules (their
  `to_json/2` functions recurse through here for nested values).
  """
  def sub_type_to_json(doc, %Yelixer.ID{client: c, clock: k}) do
    type_key = "__sub:#{c}:#{k}"

    case doc.types[type_key] do
      :text -> Yelixer.Types.Text.to_string(doc, type_key)
      :array -> Yelixer.Types.Array.to_json(doc, type_key)
      :map -> Yelixer.Types.YMap.to_json(doc, type_key)
      :xml_fragment -> xml_fragment_to_json(doc, type_key)
      _ -> nil
    end
  end

  # ⚠️ CORRECTED 2026-08-09 — the claim this comment used to make was true of
  # ONE PRERELEASE AND NOTHING ELSE. It said Yjs v14 uses a single
  # xml_fragment wire type for ALL nested CRDTs, so YArray/YMap/XmlFragment
  # would all arrive here as :xml_fragment. That was the premise of f87d43e,
  # taken from the v14 rc that /home/jes/yelixer happened to hold.
  #
  # MEASURED off the wire (each version's own UpdateDecoderV1.readTypeRef, a
  # nested type under a top-level map, positive controls in both versions):
  #
  #                     nested Text  nested Array  nested Map  nested XmlFragment
  #   v14 rc                  —            —            4              —
  #   yjs 13.6.32             2            0            1              4
  #   yjs 14.0.0-16           2            0            1              4
  #
  # ⇒ The unified-YType ENCODING was walked back along with the JS API: both
  # currently-supported lines encode nested types by their own kind, and
  # typeref 4 means what it has always meant — an actual XmlFragment.
  #
  # ⛔ So this function is NOT a catch-all for nested types. It handles
  # genuine XmlFragments, which is why sub_type_to_json/2 dispatches
  # :text/:array/:map separately above. Do not delete it on the strength of
  # "v14 doesn't do the unified thing any more" — that reasoning retires the
  # wrong half.
  #
  # The semantic shape is recovered from the items themselves: items with a
  # parent_sub field (a string key) become "attrs"; positional items
  # (parent_sub nil) become "children". Both keys are omitted when empty.
  defp xml_fragment_to_json(doc, type_key) do
    items = Yelixer.BlockStore.get_sequence(doc.store, type_key)

    attrs =
      items
      |> Enum.filter(&(&1.parent_sub != nil))
      |> Enum.reduce(%{}, fn item, acc ->
        Map.put(acc, item.parent_sub, item_to_json_value(doc, item))
      end)

    children =
      items
      |> Enum.reject(&(&1.parent_sub != nil))
      |> Enum.flat_map(&item_to_json_values(doc, &1))

    res = %{}
    res = if map_size(attrs) > 0, do: Map.put(res, "attrs", attrs), else: res
    res = if length(children) > 0, do: Map.put(res, "children", children), else: res
    res
  end

  defp item_to_json_value(doc, %Yelixer.Item{content: {:any, [value]}}),
    do: resolve_content_value(doc, value)
  defp item_to_json_value(doc, %Yelixer.Item{content: {:type, _ref}, id: id}),
    do: sub_type_to_json(doc, id)
  defp item_to_json_value(doc, %Yelixer.Item{content: {:string, s}}),
    do: resolve_content_value(doc, s)
  defp item_to_json_value(_doc, _item), do: nil

  defp item_to_json_values(doc, %Yelixer.Item{content: {:any, values}}),
    do: Enum.map(values, &resolve_content_value(doc, &1))
  defp item_to_json_values(doc, %Yelixer.Item{content: {:type, _ref}, id: id}),
    do: [sub_type_to_json(doc, id)]
  defp item_to_json_values(doc, %Yelixer.Item{content: {:string, s}}),
    do: [resolve_content_value(doc, s)]
  defp item_to_json_values(_doc, _item), do: []
end
