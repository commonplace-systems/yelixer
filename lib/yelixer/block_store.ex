defmodule Yelixer.BlockStore do
  alias Yelixer.{ID, Item, StateVector}

  @type t :: %__MODULE__{
          clients: %{non_neg_integer() => [Item.t()]},
          sequences: %{String.t() => [ID.t()]},
          client_tuples: %{non_neg_integer() => tuple()}
        }
  defstruct clients: %{}, sequences: %{}, client_tuples: %{}

  def new, do: %__MODULE__{}

  def push(%__MODULE__{clients: clients, client_tuples: ct} = store, %Item{} = item) do
    client = item.id.client
    client_blocks = Map.get(clients, client, [])
    new_blocks = client_blocks ++ [item]

    # Update tuple cache: append if cache exists, otherwise rebuild from new list
    new_tuple =
      case Map.get(ct, client) do
        nil -> List.to_tuple(new_blocks)
        existing -> :erlang.append_element(existing, item)
      end

    %{store |
      clients: Map.put(clients, client, new_blocks),
      client_tuples: Map.put(ct, client, new_tuple)
    }
  end

  def get(%__MODULE__{} = store, %ID{client: client, clock: clock}) do
    case get_tuple(store, client) do
      nil -> nil
      tuple -> bsearch_item(tuple, clock)
    end
  end

  def client_blocks(%__MODULE__{clients: clients}, client) do
    Map.get(clients, client, [])
  end

  def state_vector(%__MODULE__{clients: clients}) do
    Enum.reduce(clients, StateVector.new(), fn {client, blocks}, sv ->
      case List.last(blocks) do
        nil -> sv
        %Item{id: id, length: len} -> StateVector.set(sv, client, id.clock + len)
      end
    end)
  end

  def insert_at(%__MODULE__{} = store, type_name, index, %Item{} = item) do
    store = push(store, item)
    insert_into_sequence(store, type_name, index, item.id)
  end

  def insert_into_sequence(%__MODULE__{} = store, type_name, index, id) do
    seq = Map.get(store.sequences, type_name, [])
    seq = List.insert_at(seq, index, id)
    %{store | sequences: Map.put(store.sequences, type_name, seq)}
  end

  def split_block(%__MODULE__{} = store, %ID{client: client, clock: clock}, type_name) do
    case get_tuple(store, client) do
      nil ->
        {store, nil}

      tuple ->
        case bsearch_index(tuple, clock) do
          nil ->
            {store, nil}

          {_idx, item} when item.id.clock == clock ->
            {store, item}

          {idx, item} ->
            offset = clock - item.id.clock
            {left, right} = Item.split(item, offset)

            clients =
              Map.update!(store.clients, client, fn blocks ->
                blocks
                |> List.replace_at(idx, left)
                |> List.insert_at(idx + 1, right)
              end)

            # Invalidate tuple cache for this client (list was mutated)
            ct = Map.delete(store.client_tuples, client)

            sequences =
              case Map.get(store.sequences, type_name) do
                nil ->
                  store.sequences

                seq ->
                  seq_idx = Enum.find_index(seq, &(&1 == item.id))

                  if seq_idx != nil do
                    Map.put(store.sequences, type_name, List.insert_at(seq, seq_idx + 1, right.id))
                  else
                    store.sequences
                  end
              end

            {%{store | clients: clients, sequences: sequences, client_tuples: ct}, right}
        end
    end
  end

  def get_sequence(%__MODULE__{} = store, type_name) do
    store.sequences
    |> Map.get(type_name, [])
    |> Enum.map(&get(store, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(& &1.deleted)
  end

  # Binary search returning {index, item} or nil.
  # Uses pre-cached tuple for O(1) element access.
  @doc false
  def find_block_index(blocks, clock) when is_list(blocks) do
    tuple = List.to_tuple(blocks)
    bsearch_index(tuple, clock)
  end

  # --- Internal helpers ---

  # Get or lazily build the tuple cache for a client.
  defp get_tuple(%__MODULE__{client_tuples: ct, clients: clients}, client) do
    case Map.get(ct, client) do
      nil ->
        case Map.get(clients, client) do
          nil -> nil
          [] -> nil
          blocks -> List.to_tuple(blocks)
        end

      tuple ->
        tuple
    end
  end

  # Rebuild tuple cache entry for a client from its current blocks list.
  # Used after external mutations to store.clients.
  @doc false
  def refresh_tuple_cache(%__MODULE__{clients: clients, client_tuples: ct} = store, client) do
    case Map.get(clients, client) do
      nil ->
        %{store | client_tuples: Map.delete(ct, client)}

      blocks ->
        %{store | client_tuples: Map.put(ct, client, List.to_tuple(blocks))}
    end
  end

  # Invalidate the tuple cache for a client (after external mutation).
  @doc false
  def invalidate_tuple_cache(%__MODULE__{client_tuples: ct} = store, client) do
    %{store | client_tuples: Map.delete(ct, client)}
  end

  # Binary search on a tuple, returning the item or nil.
  defp bsearch_item(tuple, clock) do
    size = tuple_size(tuple)

    if size == 0 do
      nil
    else
      case bsearch(tuple, clock, 0, size - 1) do
        nil -> nil
        {_idx, item} -> item
      end
    end
  end

  # Binary search on a tuple, returning {index, item} or nil.
  defp bsearch_index(tuple, clock) do
    size = tuple_size(tuple)

    if size == 0 do
      nil
    else
      bsearch(tuple, clock, 0, size - 1)
    end
  end

  defp bsearch(_tuple, _clock, low, high) when low > high, do: nil

  defp bsearch(tuple, clock, low, high) do
    mid = div(low + high, 2)
    item = elem(tuple, mid)
    block_start = item.id.clock
    block_end = block_start + item.length - 1

    cond do
      clock < block_start -> bsearch(tuple, clock, low, mid - 1)
      clock > block_end -> bsearch(tuple, clock, mid + 1, high)
      true -> {mid, item}
    end
  end
end
