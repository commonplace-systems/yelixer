defmodule Yelixer.Test.FileRmRfGuard do
  @moduledoc """
  Installs and verifies the recursive-delete guard for yelixer tests.

  Being an umbrella app hid yelixer's standalone requirements: the umbrella
  supplied this guard from outside the app, so an extracted checkout could not
  even bootstrap its tests. Yelixer owns this copy because it is also a
  standalone library. The other umbrella apps continue to share the root
  implementation.

  This implementation retains whichever `File` module is active under a
  yelixer-private name. In an umbrella run it nests safely with the shared
  wrapper regardless of which test helper loads first; in a standalone run it
  wraps the standard-library module directly.
  """

  @original_file Yelixer.Test.OriginalFile
  @commit_store Module.concat(["Common" <> "place", "Store", "CommitStore"])
  @probe_key {__MODULE__, :installation_probe}
  @probe_message "yelixer rm-rf guard installation probe refused"

  def install! do
    unless Code.ensure_loaded?(@original_file) do
      original_exports = File.module_info(:exports)
      load_original_file!()
      load_guarded_file!(original_exports)
    end

    assert_installed!()
  end

  def assert_safe!(path) do
    expanded_path = path |> IO.chardata_to_string() |> Path.expand()

    if Process.get(@probe_key) == expanded_path do
      raise @probe_message
    else
      case Process.whereis(@commit_store) do
        nil ->
          :ok

        _pid ->
          captured_path = captured_dir!()

          if overlapping?(expanded_path, captured_path) do
            raise ExUnit.AssertionError,
              message: """
              File.rm_rf refused to delete the live CommitStore's directory or its contents
              deletion path: #{expanded_path}
              captured path: #{captured_path}
              """
          end
      end
    end
  end

  def captured_dir! do
    # Use dynamic calls so this standalone test support file does not acquire
    # compile-time dependencies on the parent application's modules.
    handle = apply(@commit_store, :db_handle, [])

    CubDB
    |> apply(:data_dir, [handle])
    |> Path.expand()
  end

  def assert_installed! do
    probe_path =
      System.tmp_dir!()
      |> Path.join("yelixer-rm-rf-guard-probe")
      |> Path.expand()

    Process.put(@probe_key, probe_path)

    try do
      File.rm_rf(probe_path)
      raise "File.rm_rf recursive-delete guard is not active"
    rescue
      error in RuntimeError ->
        if Exception.message(error) == @probe_message do
          IO.puts("yelixer rm-rf guard active: #{inspect(__MODULE__)}")
          :ok
        else
          reraise error, __STACKTRACE__
        end
    after
      Process.delete(@probe_key)
    end
  end

  defp overlapping?(a, b) do
    ancestor_or_equal?(a, b) or ancestor_or_equal?(b, a)
  end

  defp ancestor_or_equal?(ancestor, descendant) do
    ancestor_parts = Path.split(ancestor)
    descendant_parts = Path.split(descendant)

    Enum.take(descendant_parts, length(ancestor_parts)) == ancestor_parts
  end

  defp load_original_file! do
    {File, file_beam, _filename} = :code.get_object_code(File)

    {:ok, {File, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(file_beam, [:abstract_code])

    renamed_forms =
      Enum.map(forms, fn
        {:attribute, line, :module, File} ->
          {:attribute, line, :module, @original_file}

        form ->
          form
      end)

    original_beam =
      case :compile.forms(renamed_forms, [:return]) do
        {:ok, @original_file, beam} -> beam
        {:ok, @original_file, beam, _warnings} -> beam
      end

    {:module, @original_file} = :code.load_binary(@original_file, ~c"file.ex", original_beam)
  end

  defp load_guarded_file!(original_exports) do
    delegates =
      original_exports
      |> Enum.reject(fn {name, _arity} ->
        name in [:__info__, :module_info, :rm_rf, :rm_rf!]
      end)
      |> Enum.map(fn {name, arity} ->
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            apply(unquote(@original_file), unquote(name), [unquote_splicing(args)])
          end
        end
      end)

    guarded_file =
      quote do
        defmodule File do
          @moduledoc false

          unquote_splicing(delegates)

          def rm_rf(path) do
            Yelixer.Test.FileRmRfGuard.assert_safe!(path)
            unquote(@original_file).rm_rf(path)
          end

          def rm_rf!(path) do
            Yelixer.Test.FileRmRfGuard.assert_safe!(path)
            unquote(@original_file).rm_rf!(path)
          end
        end
      end

    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      [{File, _guarded_beam}] = Code.compile_quoted(guarded_file, __ENV__.file)
    after
      Code.compiler_options(compiler_options)
    end
  end
end

Yelixer.Test.FileRmRfGuard.install!()
