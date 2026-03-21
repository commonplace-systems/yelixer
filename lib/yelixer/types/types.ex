defmodule Yelixer.Types do
  @moduledoc """
  Helper functions for resolving nested CRDT type content to JSON-serializable values.
  """

  alias Yelixer.BlockStore

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
  Looks up the type registered for that item and serializes accordingly.
  """
  def sub_type_to_json(doc, id) do
    type_key = find_type_key_for_id(doc, id)

    case doc.types[type_key] do
      :text -> Yelixer.Types.Text.to_string(doc, type_key)
      :array -> Yelixer.Types.Array.to_list(doc, type_key)
      :map -> Yelixer.Types.YMap.to_map(doc, type_key)
      _ -> nil
    end
  end

  defp find_type_key_for_id(doc, id) do
    # Search block store for items whose parent references this ID
    # and find the corresponding type name
    Enum.find_value(doc.types, fn {name, _type} ->
      sequence = BlockStore.get_sequence(doc.store, "type_#{name}")

      if Enum.any?(sequence, fn item -> item.id == id end) do
        name
      end
    end)
  end
end
