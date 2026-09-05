# Run with MIX_ENV=test mix run; inputs and output are explicit synthetic files.
Code.require_file("compat_oracle.exs", __DIR__)
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text
alias Yelixer.Test.CompatOracle, as: O

safe = fn fun ->
  try do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e)}
  end
end

p = O.open()
input = System.fetch_env!("HISTORY_INPUT") |> File.read!() |> Jason.decode!()

rows =
  for history <- input["histories"], mode <- ["updates_hex", "full_updates_hex"] do
    O.reset(p, 900)

    {stages, _doc} =
      Enum.map_reduce(Enum.with_index(history[mode]), Doc.new(client_id: 800), fn {hex, i},
                                                                                  prior ->
        bytes = Base.decode16!(hex, case: :lower)
        doc = if mode == "full_updates_hex", do: Doc.new(client_id: 800), else: prior
        if mode == "full_updates_hex", do: O.reset(p, 900)

        {status, result} =
          safe.(fn ->
            {:ok, loaded} = Encoding.apply_update(doc, bytes)
            loaded
          end)

        {browser_status, browser} =
          safe.(fn ->
            O.apply(p, bytes)
            O.text(p)
          end)

        text = if status == :ok, do: Text.to_string(result, "content"), else: nil

        future =
          if status == :ok do
            safe.(fn ->
              reloaded = O.reload(result)
              changed = Text.insert(reloaded, "content", Text.length(reloaded, "content"), "?")
              Text.to_string(O.reload(changed), "content")
            end)
          end

        row = %{
          stage: i + 1,
          view: text,
          reader_status: status,
          reader_error: if(status == :error, do: result),
          browser_status: browser_status,
          browser_view_or_error: browser,
          writer_view: Enum.at(history["old_views"], i),
          writer_view_preserved: text == Enum.at(history["old_views"], i),
          future_reload_edit: inspect(future),
          intended_final: history["intended_final"]
        }

        {row, if(status == :ok, do: result, else: prior)}
      end)

    %{name: history["name"], writer: history["writer"], transport: mode, stages: stages}
  end

Port.close(p)
File.write!(System.fetch_env!("HISTORY_REPORT"), Jason.encode!(rows, pretty: true) <> "\n")
