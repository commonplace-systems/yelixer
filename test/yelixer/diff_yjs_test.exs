defmodule Yelixer.DiffYjsTest do
  @moduledoc """
  Differential tests comparing yelixer against Node yjs, the canonical
  JavaScript reference implementation (CX-xk6).

  Spawns a persistent node subprocess running yjs_diff_driver.mjs and
  drives the same op sequence through both yelixer and yjs, comparing
  text/map/array content and encoded binary after a reload.

  Tagged :diff_yjs so CI can isolate it for the conformance count assertion.
  """
  use ExUnit.Case, async: false

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap, Array}

  @moduletag :diff_yjs
  @driver Path.expand("../fixtures/yjs_diff_driver.mjs", __DIR__)
  @oracles ~w(stable preview)
  @oracle System.get_env("YJS_ORACLE", "stable")

  unless @oracle in @oracles do
    raise "unknown YJS_ORACLE=#{inspect(@oracle)}; expected stable or preview"
  end

  @driver_skip_reason (case System.find_executable("node") do
                         nil ->
                           "Yjs #{@oracle} driver yjs_diff_driver.mjs cannot check its import because " <>
                             "Node.js is missing; install Node.js, then run " <>
                             "`npm ci --prefix apps/yelixer/test/fixtures`"

                         node ->
                           case System.cmd(
                                  node,
                                  [@driver, "--oracle", @oracle, "--check-import"],
                                  stderr_to_stdout: true
                                ) do
                             {_output, 0} ->
                               nil

                             {_output, _status} ->
                               "Yjs #{@oracle} driver yjs_diff_driver.mjs import did not resolve; " <>
                                 "install it with `npm ci --prefix apps/yelixer/test/fixtures`"
                           end
                       end)

  if @driver_skip_reason do
    if System.get_env("YELIXER_REQUIRE_YJS_ORACLE") == "1" do
      raise @driver_skip_reason
    end

    IO.puts("SKIP Yelixer.DiffYjsTest: #{@driver_skip_reason}")
    @moduletag skip: @driver_skip_reason
  end

  # ---------------------------------------------------------------------------
  # Node driver port helpers
  # ---------------------------------------------------------------------------

  setup_all do
    {:ok, oracle: @oracle}
  end

  setup %{oracle: oracle} do
    port = open_driver(oracle)
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    {:ok, port: port}
  end

  defp open_driver(oracle) do
    Port.open(
      {:spawn_executable, System.find_executable("node")},
      [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:args, [@driver, "--oracle", oracle]}
      ]
    )
  end

  defp rpc(port, msg) do
    payload = Jason.encode!(msg) <> "\n"
    Port.command(port, payload)

    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:exit_status, n}} -> raise "driver exited with status #{n}"
    after
      5_000 -> raise "timeout waiting for driver"
    end
  end

  # ---------------------------------------------------------------------------
  # Yelixer helpers
  # ---------------------------------------------------------------------------

  defp yel_new(_client_id) do
    # Empty doc; types registered lazily on first access (matches yjs).
    Doc.new(client_id: 1)
  end

  defp yel_ensure_text(doc, name) do
    if Doc.has_type?(doc, name) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, name, :text)
      doc
    end
  end

  defp yel_ensure_map(doc, name) do
    if Doc.has_type?(doc, name) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, name, :map)
      doc
    end
  end

  defp yel_ensure_array(doc, name) do
    if Doc.has_type?(doc, name) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, name, :array)
      doc
    end
  end

  defp yel_reload(%Doc{client_id: cid} = doc) do
    bin = Encoding.encode_update(doc)
    {:ok, fresh} = Encoding.apply_update(Doc.new(client_id: cid), bin)
    fresh
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "text" do
    test "insert → encode → reload → content matches yjs", %{port: port} do
      # Yjs path
      assert %{"ok" => true} = rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello world"})
      rpc(port, %{cmd: "reload"})

      assert %{"ok" => true, "text" => yjs_text} =
               rpc(port, %{cmd: "text_content", name: "content"})

      assert yjs_text == "hello world"

      # Yelixer path
      yel = yel_new(1) |> yel_ensure_text("content") |> Text.insert("content", 0, "hello world")
      yel = yel_reload(yel)
      assert Text.to_string(yel, "content") == yjs_text
    end

    test "insert → delete from start → reload matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello world"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_text", name: "content", pos: 0, len: 1})
      rpc(port, %{cmd: "reload"})
      assert %{"text" => yjs_text} = rpc(port, %{cmd: "text_content", name: "content"})

      yel = yel_new(1) |> yel_ensure_text("content") |> Text.insert("content", 0, "hello world")
      yel = yel_reload(yel) |> Text.delete("content", 0, 1)
      yel = yel_reload(yel)
      assert Text.to_string(yel, "content") == yjs_text
    end

    test "insert → delete-all → insert new → reload matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello world"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_text", name: "content", pos: 0, len: 11})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "goodbye earth"})
      rpc(port, %{cmd: "reload"})
      assert %{"text" => yjs_text} = rpc(port, %{cmd: "text_content", name: "content"})

      yel = yel_new(1) |> yel_ensure_text("content") |> Text.insert("content", 0, "hello world")

      yel =
        yel_reload(yel)
        |> Text.delete("content", 0, 11)
        |> Text.insert("content", 0, "goodbye earth")

      yel = yel_reload(yel)
      assert Text.to_string(yel, "content") == yjs_text
    end

    test "5 cycle rehydrate with appends matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "start"})

      for i <- 1..5 do
        rpc(port, %{cmd: "reload"})

        %{"text" => t} = rpc(port, %{cmd: "text_content", name: "content"})
        rpc(port, %{cmd: "insert_text", name: "content", pos: String.length(t), text: " #{i}"})
      end

      rpc(port, %{cmd: "reload"})
      assert %{"text" => yjs_text} = rpc(port, %{cmd: "text_content", name: "content"})

      yel = yel_new(1) |> yel_ensure_text("content") |> Text.insert("content", 0, "start")

      yel =
        Enum.reduce(1..5, yel, fn i, acc ->
          acc = yel_reload(acc)
          pos = String.length(Text.to_string(acc, "content"))
          Text.insert(acc, "content", pos, " #{i}")
        end)

      yel = yel_reload(yel)
      assert Text.to_string(yel, "content") == yjs_text
    end
  end

  describe "map" do
    test "set keys → reload → content matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "set_map", root: "root", key: "a", value: "1"})
      rpc(port, %{cmd: "set_map", root: "root", key: "b", value: "2"})
      rpc(port, %{cmd: "reload"})
      assert %{"map" => yjs_map} = rpc(port, %{cmd: "map_content", name: "root"})

      yel =
        yel_new(1)
        |> yel_ensure_map("root")
        |> YMap.set("root", "a", "1")
        |> YMap.set("root", "b", "2")

      yel = yel_reload(yel)
      assert YMap.to_map(yel, "root") == yjs_map
    end

    test "set → reload → overwrite → reload matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "set_map", root: "root", key: "k", value: "v1"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "set_map", root: "root", key: "k", value: "v2"})
      rpc(port, %{cmd: "reload"})
      assert %{"map" => yjs_map} = rpc(port, %{cmd: "map_content", name: "root"})

      yel = yel_new(1) |> yel_ensure_map("root") |> YMap.set("root", "k", "v1")
      yel = yel_reload(yel) |> YMap.set("root", "k", "v2") |> yel_reload()
      assert YMap.to_map(yel, "root") == yjs_map
    end

    test "set → reload → delete key → reload matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "set_map", root: "root", key: "keep", value: "yes"})
      rpc(port, %{cmd: "set_map", root: "root", key: "drop", value: "no"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_map", root: "root", key: "drop"})
      rpc(port, %{cmd: "reload"})
      assert %{"map" => yjs_map} = rpc(port, %{cmd: "map_content", name: "root"})

      yel =
        yel_new(1)
        |> yel_ensure_map("root")
        |> YMap.set("root", "keep", "yes")
        |> YMap.set("root", "drop", "no")

      yel = yel_reload(yel) |> YMap.delete("root", "drop") |> yel_reload()
      assert YMap.to_map(yel, "root") == yjs_map
    end
  end

  describe "array" do
    test "push → reload → push more matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "push_array", root: "items", items: [1, 2, 3]})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "push_array", root: "items", items: [4, 5]})
      rpc(port, %{cmd: "reload"})
      assert %{"array" => yjs_arr} = rpc(port, %{cmd: "array_content", name: "items"})

      yel = yel_new(1) |> yel_ensure_array("items") |> Array.push("items", [1, 2, 3])
      yel = yel_reload(yel) |> Array.push("items", [4, 5]) |> yel_reload()
      assert Array.to_list(yel, "items") == yjs_arr
    end

    test "push → reload → delete first → insert replacement matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "push_array", root: "items", items: ["a", "b", "c"]})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_array", root: "items", pos: 0, len: 1})
      rpc(port, %{cmd: "insert_array", root: "items", pos: 0, items: ["A"]})
      rpc(port, %{cmd: "reload"})
      assert %{"array" => yjs_arr} = rpc(port, %{cmd: "array_content", name: "items"})

      yel = yel_new(1) |> yel_ensure_array("items") |> Array.push("items", ["a", "b", "c"])

      yel =
        yel_reload(yel)
        |> Array.delete("items", 0, 1)
        |> Array.insert("items", 0, ["A"])
        |> yel_reload()

      assert Array.to_list(yel, "items") == yjs_arr
    end
  end

  describe "envelope (root map + content text, the CX-2sv pattern)" do
    test "insert text with root metadata → reload → replace content matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "set_map", root: "root", key: "_type", value: "text"})
      rpc(port, %{cmd: "set_map", root: "root", key: "_name", value: "test.txt"})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello world"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_text", name: "content", pos: 0, len: 11})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "goodbye earth"})
      rpc(port, %{cmd: "reload"})

      assert %{"text" => yjs_text} = rpc(port, %{cmd: "text_content", name: "content"})
      assert %{"map" => yjs_map} = rpc(port, %{cmd: "map_content", name: "root"})

      yel =
        yel_new(1)
        |> yel_ensure_map("root")
        |> YMap.set("root", "_type", "text")
        |> YMap.set("root", "_name", "test.txt")
        |> yel_ensure_text("content")
        |> Text.insert("content", 0, "hello world")

      yel =
        yel_reload(yel)
        |> Text.delete("content", 0, 11)
        |> Text.insert("content", 0, "goodbye earth")
        |> yel_reload()

      assert Text.to_string(yel, "content") == yjs_text
      assert YMap.to_map(yel, "root") == yjs_map
    end

    test "envelope + delete-from-start matches yjs", %{port: port} do
      rpc(port, %{cmd: "reset", client_id: 1})
      rpc(port, %{cmd: "set_map", root: "root", key: "_type", value: "text"})
      rpc(port, %{cmd: "insert_text", name: "content", pos: 0, text: "hello"})
      rpc(port, %{cmd: "reload"})
      rpc(port, %{cmd: "delete_text", name: "content", pos: 0, len: 1})
      rpc(port, %{cmd: "reload"})

      assert %{"text" => yjs_text} = rpc(port, %{cmd: "text_content", name: "content"})

      yel =
        yel_new(1)
        |> yel_ensure_map("root")
        |> YMap.set("root", "_type", "text")
        |> yel_ensure_text("content")
        |> Text.insert("content", 0, "hello")

      yel = yel_reload(yel) |> Text.delete("content", 0, 1) |> yel_reload()
      assert Text.to_string(yel, "content") == yjs_text
    end
  end
end
