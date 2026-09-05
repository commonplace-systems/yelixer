Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.OldHistoryTest do
  use ExUnit.Case, async: false
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O

  @histories Jason.decode!(
               File.read!(Path.expand("../fixtures/old-grapheme-history.json", __DIR__))
             )["histories"]

  setup do
    p = O.open()
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    %{port: p}
  end

  for corpus <- ["pure-yjs", "candidate-utf16"],
      row <-
        Jason.decode!(File.read!(Path.expand("../fixtures/#{corpus}-history.json", __DIR__)))[
          "histories"
        ],
      mode <- ["updates_hex", "full_updates_hex"] do
    @row row
    @mode mode
    test "#{corpus} #{@row["name"]}: #{mode} preserves every stage and continued edits", %{
      port: p
    } do
      O.reset(p, 900)
      base = @row["operations"] |> hd() |> Enum.at(2)
      prefix = String.replace_suffix(base, "b", "")
      expected_stages = [base, base <> "!", prefix <> "Xb!", prefix <> "X!"]

      doc =
        Enum.with_index(@row[@mode])
        |> Enum.reduce(Doc.new(client_id: 800), fn {hex, i}, prior ->
          bytes = Base.decode16!(hex, case: :lower)
          prior = if @mode == "full_updates_hex", do: Doc.new(client_id: 800), else: prior
          if @mode == "full_updates_hex", do: O.reset(p, 900)
          O.apply(p, bytes)
          {:ok, doc} = Encoding.apply_update(prior, bytes)
          assert Text.to_string(doc, "content") == Enum.at(expected_stages, i)
          assert O.text(p) == Enum.at(expected_stages, i)
          assert O.sv(p) == Doc.state_vector(doc)
          O.reload(doc)
        end)

      assert Text.to_string(doc, "content") == @row["intended_final"]
      doc = Text.insert(doc, "content", Text.length(doc, "content"), "?")
      O.apply(p, Encoding.encode_diff(doc, O.sv(p)))
      assert O.text(p) == @row["intended_final"] <> "?"
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: "^"})
      {:ok, doc} = Encoding.apply_update(doc, O.update(p, Doc.state_vector(doc)))
      assert Text.to_string(O.reload(doc), "content") == "^" <> @row["intended_final"] <> "?"
    end
  end

  test "immutable old ASCII history preserves each view and supports future edits", %{port: p} do
    row = Enum.find(@histories, &(&1["name"] == "ascii"))
    O.reset(p, 200)

    doc =
      Enum.zip(row["updates_hex"], row["old_views"])
      |> Enum.reduce(Doc.new(client_id: 300), fn {hex, expected}, doc ->
        bytes = Base.decode16!(hex, case: :lower)
        O.apply(p, bytes)
        {:ok, doc} = Encoding.apply_update(doc, bytes)
        assert O.text(p) == expected
        assert Text.to_string(doc, "content") == expected
        assert O.sv(p) == Doc.state_vector(doc)
        O.reload(doc)
      end)

    doc = Text.insert(doc, "content", 3, "?")
    O.apply(p, Encoding.encode_diff(doc, O.sv(p)))
    assert O.text(p) == "aX!?"
  end

  test "an old single Unicode insertion is readable and has no wire clock-convention label", %{
    port: p
  } do
    for row <- Enum.reject(@histories, &(&1["name"] == "ascii")) do
      [first | _] = row["updates_hex"]
      [text | _] = row["old_views"]
      bytes = Base.decode16!(first, case: :lower)
      assert Text.to_string(O.load(bytes), "content") == text
      # The same bytes can be authored independently by real Yjs. Provenance
      # cannot be classified from the update alone, even with a UTF-16 reader.
      O.reset(p, row["author"])
      O.rpc(p, %{cmd: "insert_text", pos: 0, text: text})
      assert O.update(p) == bytes
    end
  end
end
