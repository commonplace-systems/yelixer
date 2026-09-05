Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.UnicodeBoundaryTest do
  use ExUnit.Case, async: false
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O

  # Adoption blocker: browser-authored surrogate-interior operations must
  # either converge or be explicitly rejected. Local B-up tests cannot prove it.
  @tag :divergence
  test "a browser half-surrogate edit cannot silently diverge on receipt" do
    p = O.open()
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    O.reset(p, 100)
    O.rpc(p, %{cmd: "insert_text", pos: 0, text: "\u{1F600}A"})
    doc = O.load(O.update(p), 200)
    O.rpc(p, %{cmd: "insert_text", pos: 1, text: "X"})
    assert O.text(p) == "\u{FFFD}X\u{FFFD}A"

    case Encoding.apply_update(doc, O.update(p, Doc.state_vector(doc))) do
      {:error, _explicit_refusal} -> :ok
      {:ok, received} -> assert Text.to_string(received, "content") == O.text(p)
    end
  end
end
