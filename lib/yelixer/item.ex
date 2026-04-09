defmodule Yelixer.Item do
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
  Split an item at a given offset, returning {left, right}.

  Left keeps the original ID, origin, and right_origin with reduced length.
  Right gets ID {client, clock + offset}, origin pointing at the last clock
  of the left half, and inherits the original's right_origin.

  This matches yrs/yjs split semantics: both halves conceptually occupy the
  same YATA position as the original item, so they share the original's
  right_origin. Setting left.right_origin = right.id (the previous buggy
  behavior) broke the invariant that leftmost sequence items have
  right_origin=nil, which in turn caused encoded commits of rehydrated-
  then-modified docs to lose their parent linkage on decode (CX-2sv).
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
      origin: ID.new(item.id.client, item.id.clock + offset - 1),
      right_origin: item.right_origin,
      content: right_content,
      parent: item.parent,
      parent_sub: item.parent_sub,
      deleted: item.deleted,
      length: content_length(right_content)
    }

    {left, right}
  end

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

  defp content_length({:gc, n}), do: n
  defp content_length({:string, s}), do: String.length(s)
  defp content_length({:any, list}), do: length(list)
  defp content_length({:binary, b}), do: byte_size(b)
  defp content_length({:deleted, n}), do: n
  defp content_length({:json, list}), do: length(list)
  defp content_length(_), do: 1
end
