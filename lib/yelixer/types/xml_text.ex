defmodule Yelixer.Types.XMLText do
  @moduledoc """
  Plain collaborative text inside an XML tree.

  The parent registers this type under its child key. Positions count UTF-16
  code units, using the same local upward-clamp policy as `Yelixer.Types.Text`.
  Delete endpoints normalize independently. Incoming wire clocks are handled
  separately by the codec; local clamping does not change their interpretation.

  These operations share Text's implementation so fixes to boundaries, empty
  inserts and sequence membership also apply to XML text. Rich-text formatting
  positions remain outside the plain-text facade's parity guarantee.
  """

  alias Yelixer.Types.Text

  @doc "Inserts text at a local UTF-16 position."
  defdelegate insert(doc, type_name, index, text), to: Text

  @doc "Deletes a local UTF-16 interval with independently normalized endpoints."
  defdelegate delete(doc, type_name, index, length), to: Text

  @doc "Renders live string content."
  defdelegate to_string(doc, type_name), to: Text

  @doc "Returns the plain sequence's live UTF-16 length."
  defdelegate length(doc, type_name), to: Text
end
