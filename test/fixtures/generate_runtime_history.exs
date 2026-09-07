# Run under the named writer checkout with MIX_ENV=test. The mixed arm deliberately
# runs under the old grapheme writer; its first update comes from real Yjs.
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

source = System.fetch_env!("HISTORY_SOURCE") |> File.read!() |> Jason.decode!()
mixed? = System.get_env("HISTORY_MODE") == "mixed"
writer = System.fetch_env!("HISTORY_WRITER")

rows =
  for h <- source["histories"] do
    base = hd(h["old_views"])
    prefix = String.replace_suffix(base, "b", "")
    units = fn text -> div(byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)), 2) end

    {a, append_at, insert_at} =
      if mixed? do
        {:ok, a} =
          Encoding.apply_update(
            Doc.new(client_id: 200),
            Base.decode16!(hd(h["updates_hex"]), case: :lower)
          )

        {a, String.length(base), String.length(prefix)}
      else
        {Text.insert(Doc.new(client_id: 100), "content", 0, base), units.(base), units.(prefix)}
      end

    b = Text.insert(a, "content", append_at, "!")
    c = Text.insert(b, "content", insert_at, "X")
    d = Text.delete(c, "content", insert_at + 1, 1)
    docs = [a, b, c, d]

    {updates, _} =
      Enum.map_reduce(docs, Doc.new(client_id: 800), fn doc, prev ->
        {Base.encode16(Encoding.encode_diff(doc, Doc.state_vector(prev)), case: :lower), doc}
      end)

    %{
      name: h["name"],
      writer: writer,
      origin: if(mixed?, do: "Yjs base; old fresh server author", else: "candidate"),
      authors: if(mixed?, do: [100, 200], else: [100]),
      operations: [
        ["insert", 0, base],
        ["insert", append_at, "!"],
        ["insert", insert_at, "X"],
        ["delete", insert_at + 1, 1]
      ],
      coordinate_contract:
        if(mixed?,
          do: "Yjs base UTF-16; old server grapheme positions",
          else: "UTF-16 scalar boundaries"
        ),
      updates_hex: updates,
      full_updates_hex: Enum.map(docs, &Base.encode16(Encoding.encode_update(&1), case: :lower)),
      old_views: Enum.map(docs, &Text.to_string(&1, "content")),
      intended_final: prefix <> "X!"
    }
  end

File.write!(
  System.fetch_env!("HISTORY_OUTPUT"),
  Jason.encode!(%{schema: 1, histories: rows}, pretty: true) <> "\n"
)
