defmodule Yelixer.Any do
  @moduledoc """
  Explicit lib0 Any values whose JavaScript types have no distinct ordinary
  Elixir representation.

  `buffer/1` represents a JavaScript `Uint8Array`; an ordinary Elixir binary
  still encodes as a JavaScript string. `undefined/0` is distinct from `nil`
  (JavaScript null). `bigint/1` represents a signed 64-bit JavaScript bigint;
  an ordinary Elixir integer still encodes as a JavaScript number.

  The codec returns these wrappers when decoding their wire tags and accepts
  them in map/array values and nested Any containers. Consumers that need JSON
  must choose an explicit application representation for them: JSON cannot
  preserve these distinctions on its own.

  This concerns Any content. An Item with `{:binary, bytes}` is the separate
  Yjs ContentBinary struct and retains its existing representation.
  """

  @enforce_keys [:type]
  defstruct [:type, :value]

  @type t :: %__MODULE__{
          type: :buffer | :undefined | :bigint,
          value: binary() | integer() | nil
        }

  @doc "A byte buffer, distinct from an ordinary binary string."
  @spec buffer(binary()) :: t()
  def buffer(bytes) when is_binary(bytes), do: %__MODULE__{type: :buffer, value: bytes}

  @doc "JavaScript undefined, distinct from null (`nil`)."
  @spec undefined() :: t()
  def undefined, do: %__MODULE__{type: :undefined}

  @doc "A signed 64-bit bigint. Raises ArgumentError outside that wire range."
  @spec bigint(integer()) :: t()
  def bigint(value)
      when is_integer(value) and value >= -9_223_372_036_854_775_808 and
             value <= 9_223_372_036_854_775_807,
      do: %__MODULE__{type: :bigint, value: value}

  def bigint(_), do: raise(ArgumentError, "Any bigint requires a signed 64-bit integer")
end
