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
      _ -> nil
    end
  end
end
