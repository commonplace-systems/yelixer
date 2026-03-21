defmodule Yelixer.BlockStore do
  alias Yelixer.{ID, Item, StateVector}

  @type t :: %__MODULE__{
          clients: %{non_neg_integer() => [Item.t()]},
          sequences: %{String.t() => [ID.t()]}
        }
  defstruct clients: %{}, sequences: %{}

  def new, do: %__MODULE__{}

  def push(%__MODULE__{clients: clients} = store, %Item{} = item) do
    client_blocks = Map.get(clients, item.id.client, [])
    %{store | clients: Map.put(clients, item.id.client, client_blocks ++ [item])}
  end

  def get(%__MODULE__{clients: clients}, %ID{client: client, clock: clock}) do
    case Map.get(clients, client) do
      nil -> nil
      blocks -> find_block(blocks, clock)
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
    item = get(store, %ID{client: client, clock: clock})

    if item == nil do
      {store, nil}
    else
      if item.id.clock == clock do
        {store, item}
      else
        offset = clock - item.id.clock
        {left, right} = Item.split(item, offset)

        clients =
          Map.update!(store.clients, client, fn blocks ->
            idx = Enum.find_index(blocks, &(&1.id == item.id))

            blocks
            |> List.replace_at(idx, left)
            |> List.insert_at(idx + 1, right)
          end)

        sequences =
          case Map.get(store.sequences, type_name) do
            nil ->
              store.sequences

            seq ->
              idx = Enum.find_index(seq, &(&1 == item.id))

              if idx != nil do
                Map.put(store.sequences, type_name, List.insert_at(seq, idx + 1, right.id))
              else
                store.sequences
              end
          end

        {%{store | clients: clients, sequences: sequences}, right}
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

  defp find_block(blocks, clock) do
    Enum.find(blocks, fn %Item{id: id, length: len} ->
      clock >= id.clock and clock < id.clock + len
    end)
  end
end
