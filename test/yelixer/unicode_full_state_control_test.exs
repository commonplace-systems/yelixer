Code.require_file("../support/compat_oracle.exs", __DIR__)

defmodule Yelixer.UnicodeFullStateControlTest do
  use ExUnit.Case, async: false
  alias Yelixer.Doc
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O

  @fixture Jason.decode!(
             File.read!(Path.expand("../fixtures/incoming-half-surrogate.json", __DIR__))
           )["histories"]
           |> hd()
  @expected "\u{FFFD}X\u{FFFD}A"

  setup do
    p = O.open()
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    %{port: p}
  end

  test "fresh final full-state loading is a separate passing control", %{port: p} do
    full = @fixture["full_updates_hex"] |> List.last() |> Base.decode16!(case: :lower)
    O.reset(p, 900)
    O.apply(p, full)
    doc = O.load(full, 200)
    assert O.text(p) == @expected
    assert Text.to_string(doc, "content") == @expected
    assert Doc.state_vector(doc) == O.sv(p)
  end
end
