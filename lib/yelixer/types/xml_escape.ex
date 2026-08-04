defmodule Yelixer.Types.XMLEscape do
  @moduledoc """
  Shared XML/XHTML escaping for the `to_string/2` serializers in the XML
  type family (`Yelixer.Types.XMLElement`, `Yelixer.Types.XMLFragment`).

  STORE-RAW + ESCAPE-ON-OUTPUT: the CRDT text store always holds exactly
  what was typed (audit fidelity — see `Yelixer.Types.XMLText.to_string/2`,
  which stays raw on purpose because `Yelixer.Doc`'s fork/copy replay path
  reads through it as an internal data-extraction primitive, not as web
  output). Escaping happens here, once, at the point where text and
  attribute values are woven into the `<tag attr="...">text</tag>` string
  — the only surface that gets raw-rendered on a web page (CX-n3i7).

  No Yelixer XML parser exists that consumes `to_string/2` output (doc
  reconstruction/fork/merge walks the CRDT structurally — see
  `Yelixer.Doc`'s `replay_xml_*` — never by re-parsing this string), so
  there is no double-escaping hazard to guard against here.
  """

  @doc "Escape text content for the `>text<` position: `&`, `<`, `>`."
  def text(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  Escape an attribute value for the `key="..."` position: `&`, `<`, `>`,
  `"`, and `'`.
  """
  def attribute(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end
end
