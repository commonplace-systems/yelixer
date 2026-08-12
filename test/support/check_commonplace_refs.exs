defmodule YelixerCommonplaceBoundary do
  @moduledoc false

  def run(root) do
    violations =
      root
      |> source_files()
      |> Enum.flat_map(&violations/1)

    case violations do
      [] ->
        IO.puts("yelixer boundary check passed: no executable Common" <> "place references")
        :ok

      violations ->
        IO.puts(
          :stderr,
          "yelixer boundary check failed: executable Common" <> "place references found"
        )

        Enum.each(violations, &IO.puts(:stderr, &1))
        :error
    end
  end

  defp source_files(root) do
    yelixer_root =
      if File.dir?(Path.join([root, "apps", "yelixer"])) do
        Path.join([root, "apps", "yelixer"])
      else
        root
      end

    ["lib", "test"]
    |> Enum.flat_map(fn directory ->
      Path.wildcard(Path.join([yelixer_root, directory, "**", "*.{ex,exs}"]))
    end)
    |> Enum.sort()
  end

  defp violations(path) do
    path
    |> File.read!()
    |> strip_prose()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(~r/\bCommonplace\b/, line) do
        ["#{path}:#{line_number}:#{String.trim(line)}"]
      else
        []
      end
    end)
  end

  # Preserve newlines for actionable locations while removing the two prose
  # forms allowed to mention Commonplace: line comments and heredoc bodies.
  #
  # ⚠️ STRING BODIES ARE DELIBERATELY *NOT* MASKED, AND MUST NOT BE.
  #
  # If you are reading this because the checker flagged a harmless mention
  # inside a plain string literal, the fix you are about to make — treating
  # `"..."` like a comment — opens a silent hole: `"val: #{Commonplace.Store.get(x)}"`
  # is EXECUTABLE code inside a string, and masking string bodies stops
  # flagging it. The checker would go quietly green on a real boundary
  # violation, which is the exact failure this whole check exists to prevent.
  #
  # This scanner is therefore built to fail toward FALSE RED: an unmatched
  # quote or an odd `?"` literal leaves it preserving bytes, never masking
  # them. A false red is a two-minute conversation; a false green is
  # invisible until an extraction fails months later. If a legitimate string
  # mention appears, rename the string's content or add a narrow exclusion —
  # do not widen the masker.
  #
  # Verified by probe 2026-08-08: plain alias, `#{...}` interpolation inside a
  # string, a `?"` char literal, and a sigil-then-alias were all caught.
  defp strip_prose(source), do: scan(source, :code, []) |> IO.iodata_to_binary()

  defp scan(<<>>, _state, acc), do: Enum.reverse(acc)

  defp scan(<<"\"\"\"", rest::binary>>, :code, acc),
    do: scan(rest, :heredoc, ["   " | acc])

  defp scan(<<"\"\"\"", rest::binary>>, :heredoc, acc),
    do: scan(rest, :code, ["   " | acc])

  defp scan(<<"\n", rest::binary>>, :heredoc, acc),
    do: scan(rest, :heredoc, ["\n" | acc])

  defp scan(<<_byte, rest::binary>>, :heredoc, acc),
    do: scan(rest, :heredoc, [" " | acc])

  defp scan(<<"#", rest::binary>>, :code, acc),
    do: scan(rest, :comment, [" " | acc])

  defp scan(<<"\n", rest::binary>>, :comment, acc),
    do: scan(rest, :code, ["\n" | acc])

  defp scan(<<_byte, rest::binary>>, :comment, acc),
    do: scan(rest, :comment, [" " | acc])

  defp scan(<<quote, rest::binary>>, :code, acc) when quote in [?\", ?'],
    do: scan(rest, {:string, quote}, [quote | acc])

  defp scan(<<"\\", escaped, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, {:string, quote}, [escaped, ?\\ | acc])

  defp scan(<<quote, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, :code, [quote | acc])

  defp scan(<<byte, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, {:string, quote}, [byte | acc])

  defp scan(<<byte, rest::binary>>, :code, acc),
    do: scan(rest, :code, [byte | acc])
end

root = System.argv() |> List.first() |> then(&(&1 || File.cwd!())) |> Path.expand()

case YelixerCommonplaceBoundary.run(root) do
  :ok -> System.halt(0)
  :error -> System.halt(1)
end
