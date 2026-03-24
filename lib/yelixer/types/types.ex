defmodule Yelixer.Types do
  @moduledoc """
  Helper functions for resolving nested CRDT type content to JSON-serializable values.
  """

  @doc """
  Resolve a content value to its JSON representation.
  Passes through primitives, resolves nested types recursively.
  """
  def resolve_content_value(_doc, value) when is_binary(value), do: value
  def resolve_content_value(_doc, value) when is_number(value), do: value
  def resolve_content_value(_doc, value) when is_boolean(value), do: value
  def resolve_content_value(_doc, nil), do: nil
  def resolve_content_value(_doc, value) when is_list(value), do: value
  def resolve_content_value(_doc, value) when is_map(value), do: value
  def resolve_content_value(_doc, value), do: value

  @doc """
  Convert a nested sub-type (identified by its parent item ID) to JSON.
  The parent item's ID determines the type key ("__sub:CLIENT:CLOCK"),
  which is how apply_update registers sub-types during integration.
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

  # Yjs v14 unified YType uses xml_fragment for all nested types.
  # toJSON() includes "attrs" (map entries) and/or "children" (array entries),
  # only when non-empty.
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
