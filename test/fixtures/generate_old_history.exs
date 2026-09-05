alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

rows =
  for {name, text, append_at, insert_at} <- [
        {"ascii", "ab", 2, 1},
        {"combining", "e\u{0301}b", 2, 1},
        {"astral", "\u{1F600}b", 2, 1},
        {"zwj", "\u{1F469}\u{200D}\u{1F4BB}b", 2, 1}
      ] do
    a = Text.insert(Doc.new(client_id: 100), "content", 0, text)
    b = Text.insert(a, "content", append_at, "!")
    c = Text.insert(b, "content", insert_at, "X")
    d = Text.delete(c, "content", insert_at + 1, 1)
    docs = [a, b, c, d]

    {updates, _} =
      Enum.map_reduce(docs, Doc.new(client_id: 100), fn doc, prev ->
        {Base.encode16(Encoding.encode_diff(doc, Doc.state_vector(prev)), case: :lower), doc}
      end)

    %{
      name: name,
      author: 100,
      origin: "yelixer",
      writer: "bc35a0e9ff374449c71fb29be159bd9a711635bb",
      operations: [
        ["insert", 0, text],
        ["insert", append_at, "!"],
        ["insert", insert_at, "X"],
        ["delete", insert_at + 1, 1]
      ],
      coordinate_contract: "old writer grapheme positions",
      updates_hex: updates,
      old_views: Enum.map(docs, &Text.to_string(&1, "content")),
      full_updates_hex: Enum.map(docs, &Base.encode16(Encoding.encode_update(&1), case: :lower)),
      intended_final: String.first(text) <> "X!"
    }
  end

File.write!(
  System.fetch_env!("HISTORY_OUTPUT"),
  Jason.encode!(%{schema: 1, histories: rows}, pretty: true) <> "\n"
)
