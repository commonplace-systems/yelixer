defmodule Yelixer.Types do
  @moduledoc """
  Routing utilities for the type-side facades — primitive
  passthrough plus the nested-sub-type read path.

  This module has no state of its own. It exists for two reasons:

    - **Pass primitive values through unchanged** so the facades'
      `to_json/2` / `to_map/2` paths can call one helper for every
      element value regardless of its runtime type.
    - **Resolve nested CRDT sub-types** when a parent block carries
      `{:type, type_ref}` content. This is the read-path
      counterpart of the `__sub:CLIENT:CLOCK` synthetic naming
      scheme used by `Yelixer.Doc`, `Yelixer.Types.YMap`, and the
      XML modules — the loop those modules talk about minting
      finally gets *applied* here.

  ## Closing the synthetic-naming loop

  `Yelixer.Doc`'s "Sub-types and the `__sub:CLIENT:CLOCK` naming"
  section describes how nested CRDTs are registered: when a
  `YMap.set/4` value or a `YArray.insert/4` element happens to be
  itself a sub-type, the parent block holds `{:type, type_ref}` and
  the sub-type's children are registered in `doc.types` under a
  synthesized name `"__sub:CLIENT:CLOCK"` derived from the parent
  block's id.

  `sub_type_to_json/2` is the read side of that contract: given a
  parent block's id, it reconstructs the synthetic name, looks up
  the registered type, and dispatches to the appropriate
  `to_string` / `to_json` facade — `Text`, `Array`, `YMap`, or the
  XML-fragment-based unified shape from Yjs v14. Recursive: a
  sub-type containing another sub-type just calls back here.

  ## Why this is utility-shaped

  No struct, no state, no GenServer. The functions are pure routing
  + pattern matching. The module sits between the facade layer
  (`Text.to_string`, `YMap.to_json`, etc.) and the `BlockStore`
  read path; it exists so the facades can call one helper rather
  than duplicating "is this a primitive? a sub-type? a nested
  CRDT?" logic per facade.

  ## What this module is NOT

  - Not a content-variant encoder — `Yelixer.Encoding` owns the
    bytes-out path.
  - Not a sub-type creator — `YMap.set/4`, `Array.insert/4`, and
    the XML insert paths register synthetic names; this module
    only consumes them.
  - Not the BlockStore — see `Yelixer.BlockStore`. This module
    reads from it via `get_sequence/2`.
  """

  @doc """
  Pass-through resolver for primitive values.

  Every clause returns its input unchanged — strings, numbers,
  booleans, `nil`, lists, and maps all flow through. The catch-all
  at the end means anything else (atoms, tuples, structs) also
  passes through verbatim. Why so many explicit clauses then? They
  document the JSON-shape contract: `to_json` callers can rely on
  primitives surviving the round-trip.

  This function does **not** recurse into sub-types — values that
  carry CRDT structure (a YMap reachable via a parent item id, a
  nested array's contents) are routed through `sub_type_to_json/2`
  by the calling facade, not by this function.
  """
  def resolve_content_value(_doc, value) when is_binary(value), do: value
  def resolve_content_value(_doc, value) when is_number(value), do: value
  def resolve_content_value(_doc, value) when is_boolean(value), do: value
  def resolve_content_value(_doc, nil), do: nil
  def resolve_content_value(_doc, value) when is_list(value), do: value
  def resolve_content_value(_doc, value) when is_map(value), do: value
  def resolve_content_value(_doc, value), do: value

  @doc """
  Reads a nested CRDT sub-type and returns its JSON-shaped content.

  Given the id of a parent Item whose content is `{:type, type_ref}`,
  this function:

    1. Reconstructs the synthetic registration name —
       `"__sub:<client>:<clock>"` — from the parent id.
    2. Looks up `doc.types[name]` to find what kind of sub-type
       was registered when the parent was inserted. The kinds are
       the symbolic refs `Yelixer.Doc.get_or_create_type/3` accepts:
       `:text`, `:array`, `:map`, `:xml_fragment`.
    3. Dispatches to the right facade's read path —
       `Text.to_string`, `Array.to_json`, `YMap.to_json`, or the
       Yjs-v14 unified XML-fragment-as-anything shape via
       `xml_fragment_to_json/2` below.
    4. Returns `nil` for unrecognized refs.

  This is the read side of the synthetic-naming contract documented
  in `Yelixer.Doc` (write side: parent insertion mints the name)
  and `Yelixer.Types.YMap` / `Yelixer.Types.XMLFragment` (call
  sites: their `to_json/2` recurses through this function).
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

  # Yjs v14 collapsed all nested CRDT shapes into a single XML-
  # fragment-like type at the wire level: every nested-type block
  # arrives here as `:xml_fragment` regardless of whether it was
  # authored as a YArray, YMap, or actual XML fragment. The runtime
  # shape is recovered from the items inside it: items with a
  # `parent_sub` (key) become "attrs"; items without (positional
  # children) become "children". Both keys are omitted when empty
  # so the JSON output stays compact for the common case.
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
