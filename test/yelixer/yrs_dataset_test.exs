defmodule Yelixer.YrsDatasetTest do
  @moduledoc """
  Tests ported from y-crdt/yrs compatibility_tests.rs test_data_set().
  Reads binary dataset files containing randomized test cases with
  multiple updates per test, checking text, map, and array output.
  """
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Encoding, Types.Text, Types.Array, Types.YMap}

  @moduletag :dataset

  @small_dataset_path Path.expand("../fixtures/small-test-dataset.bin", __DIR__)

  test "small dataset: all text outputs match" do
    data = File.read!(@small_dataset_path)
    {test_count, rest} = Encoding.decode_uint(data)

    {pass, fail, crash, errors, _} =
      Enum.reduce(1..test_count, {0, 0, 0, [], rest}, fn n, {pass, fail, crash, errors, rest} ->
        {updates_len, rest} = Encoding.decode_uint(rest)

        {doc, rest, ok?} =
          apply_updates(rest, updates_len, new_doc())

        {expected_text, rest} = read_string(rest)
        {_expected_map, rest} = read_any(rest)
        {_expected_array, rest} = read_any(rest)

        if not ok? do
          {pass, fail, crash + 1, ["Test #{n}: crash" | errors], rest}
        else
          actual_text = Text.to_string(doc, "text")

          if actual_text == expected_text do
            {pass + 1, fail, crash, errors, rest}
          else
            {pass, fail + 1, crash, ["Test #{n}: text mismatch" | errors], rest}
          end
        end
      end)

    if fail > 0 or crash > 0 do
      error_sample = errors |> Enum.reverse() |> Enum.take(20) |> Enum.join("\n")
      flunk("#{fail} mismatches, #{crash} crashes out of #{test_count} (#{pass} passed):\n#{error_sample}")
    end
  end

  test "small dataset: first 100 tests full validation (text + map + array)" do
    data = File.read!(@small_dataset_path)
    {test_count, rest} = Encoding.decode_uint(data)
    run_count = min(test_count, 100)

    {pass, fail, crash, errors, _rest} =
      Enum.reduce(1..run_count, {0, 0, 0, [], rest}, fn test_num, {pass, fail, crash, errors, rest} ->
        {updates_len, rest} = Encoding.decode_uint(rest)

        {doc, rest, ok?} = apply_updates(rest, updates_len, new_doc())

        {expected_text, rest} = read_string(rest)
        {expected_map, rest} = read_any(rest)
        {expected_array, rest} = read_any(rest)

        if not ok? do
          {pass, fail, crash + 1, ["Test #{test_num}: crash during apply_update" | errors], rest}
        else
          actual_text = Text.to_string(doc, "text")

          {map_ok, array_ok, map_detail, array_detail} =
            try do
              actual_map = YMap.to_json(doc, "map")
              actual_array = Array.to_json(doc, "array")
              m_ok = json_equal?(actual_map, expected_map)
              a_ok = json_equal?(actual_array, expected_array)
              m_detail = if not m_ok, do: "\n  map expected: #{inspect(expected_map)}\n  map actual:   #{inspect(actual_map)}", else: ""
              a_detail = if not a_ok, do: "\n  arr expected: #{inspect(expected_array)}\n  arr actual:   #{inspect(actual_array)}", else: ""
              {m_ok, a_ok, m_detail, a_detail}
            rescue
              e ->
                {false, false, "\n  map/array error: #{inspect(e)}", ""}
            end

          text_ok = actual_text == expected_text

          if text_ok and map_ok and array_ok do
            {pass + 1, fail, crash, errors, rest}
          else
            error = "Test #{test_num}:" <>
              (if !text_ok, do: " text mismatch", else: "") <>
              (if !map_ok, do: " map mismatch", else: "") <>
              (if !array_ok, do: " array mismatch", else: "") <>
              map_detail <> array_detail
            {pass, fail + 1, crash, [error | errors], rest}
          end
        end
      end)

    if fail > 0 or crash > 0 do
      error_sample = errors |> Enum.reverse() |> Enum.take(20) |> Enum.join("\n")
      flunk("#{fail} mismatches, #{crash} crashes out of #{run_count} (#{pass} passed):\n#{error_sample}")
    end
  end

  # --- Dataset binary helpers ---

  defp apply_updates(rest, 0, doc), do: {doc, rest, true}

  defp apply_updates(rest, count, doc) do
    Enum.reduce(1..count, {doc, rest, true}, fn _, {doc, rest, ok?} ->
      {buf, rest} = read_buf(rest)

      if ok? do
        try do
          {:ok, doc} = Encoding.apply_update(doc, buf)
          {doc, rest, true}
        rescue
          _ -> {doc, rest, false}
        end
      else
        # Skip remaining buffers after a crash
        {doc, rest, false}
      end
    end)
  end

  defp new_doc do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    {doc, _} = Doc.get_or_create_type(doc, "map", :map)
    {doc, _} = Doc.get_or_create_type(doc, "array", :array)
    doc
  end

  defp read_buf(binary) do
    {len, rest} = Encoding.decode_uint(binary)
    <<buf::binary-size(len), rest2::binary>> = rest
    {buf, rest2}
  end

  defp read_string(binary) do
    {len, rest} = Encoding.decode_uint(binary)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # lib0 Any decoding — correct tag mapping:
  # 116=buffer, 117=array, 118=object, 119=string
  # 120=true, 121=false (lib0 convention: data ? 120 : 121)
  # 122=bigint, 123=float64
  # 124=float32, 125=integer(lib0 writeVarInt), 126=null, 127=undefined
  defp read_any(<<127, rest::binary>>), do: {nil, rest}
  defp read_any(<<126, rest::binary>>), do: {nil, rest}
  defp read_any(<<120, rest::binary>>), do: {true, rest}
  defp read_any(<<121, rest::binary>>), do: {false, rest}
  defp read_any(<<119, rest::binary>>), do: read_string(rest)

  defp read_any(<<123, f::float-64, rest::binary>>) do
    rounded = round(f)
    {if(rounded == f, do: rounded, else: f), rest}
  end

  defp read_any(<<124, f::float-32, rest::binary>>) do
    rounded = round(f)
    {if(rounded == f, do: rounded, else: f), rest}
  end

  defp read_any(<<125, _::binary>> = data) do
    Encoding.decode_any_value(data)
  end

  defp read_any(<<122, n::signed-64, rest2::binary>>), do: {n, rest2}

  defp read_any(<<118, rest::binary>>) do
    {len, rest} = Encoding.decode_uint(rest)
    read_any_map(rest, len, %{})
  end

  defp read_any(<<117, rest::binary>>) do
    {len, rest} = Encoding.decode_uint(rest)
    read_any_list(rest, len, [])
  end

  defp read_any(<<116, rest::binary>>) do
    {len, rest} = Encoding.decode_uint(rest)
    <<buf::binary-size(len), rest2::binary>> = rest
    {buf, rest2}
  end

  defp read_any_list(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp read_any_list(rest, n, acc) do
    {val, rest} = read_any(rest)
    read_any_list(rest, n - 1, [val | acc])
  end

  defp read_any_map(rest, 0, acc), do: {acc, rest}

  defp read_any_map(rest, n, acc) do
    {key, rest} = read_string(rest)
    {val, rest} = read_any(rest)
    read_any_map(rest, n - 1, Map.put(acc, key, val))
  end

  # JSON equality that handles nested structures
  defp json_equal?(a, b) when is_map(a) and is_map(b) do
    Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort() and
      Enum.all?(Map.keys(a), fn k -> json_equal?(Map.get(a, k), Map.get(b, k)) end)
  end

  defp json_equal?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and
      Enum.zip(a, b) |> Enum.all?(fn {x, y} -> json_equal?(x, y) end)
  end

  defp json_equal?(a, b), do: a == b
end
