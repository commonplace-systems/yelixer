defmodule Yelixer.Test.CompatOracle do
  @moduledoc false
  import ExUnit.Assertions
  alias Yelixer.{Doc, Encoding, StateVector}

  def open(driver \\ Path.expand("../fixtures/yjs_diff_driver.mjs", __DIR__)) do
    node = System.find_executable("node") || raise "Node oracle is required"

    {output, status} =
      System.cmd(node, [driver, "--oracle", "stable", "--check-import"], stderr_to_stdout: true)

    assert status == 0, "Stable Yjs oracle is required: #{output}"

    Port.open({:spawn_executable, node}, [
      :binary,
      :exit_status,
      {:line, 1_000_000},
      {:args, [driver, "--oracle", "stable"]}
    ])
  end

  def rpc(port, command) do
    Port.command(port, Jason.encode!(command) <> "\n")

    reply =
      receive do
        {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
        {^port, {:exit_status, code}} -> raise "Yjs oracle exited: #{code}"
      after
        10_000 -> raise "Yjs oracle timeout"
      end

    if path = System.get_env("COMPAT_TRANSCRIPT") do
      File.write!(path, Jason.encode!(%{command: command, reply: reply}) <> "\n", [:append])
    end

    assert reply["ok"], "Yjs rejected #{inspect(command)}: #{inspect(reply)}"
    reply
  end

  def reset(port, id), do: rpc(port, %{cmd: "reset", client_id: id})

  def apply(port, bytes),
    do: rpc(port, %{cmd: "apply_update", update_hex: Base.encode16(bytes, case: :lower)})

  def text(port, name \\ "content"), do: rpc(port, %{cmd: "text_content", name: name})["text"]

  def update(port, sv \\ nil) do
    command = if sv, do: %{cmd: "encode", sv: sv.clocks}, else: %{cmd: "encode"}
    Base.decode16!(rpc(port, command)["update_hex"], case: :lower)
  end

  def sv(port) do
    %StateVector{
      clocks:
        Map.new(rpc(port, %{cmd: "state_vector"})["sv"], fn {k, v} ->
          {String.to_integer(k), v}
        end)
    }
  end

  def load(bytes, id \\ 900) do
    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: id), bytes)
    doc
  end

  def reload(doc), do: load(Encoding.encode_update(doc), doc.client_id)
end
