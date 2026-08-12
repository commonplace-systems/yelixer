defmodule Yelixer.CommonplaceBoundaryTest do
  use ExUnit.Case, async: true

  @app_root Path.expand("../..", __DIR__)
  @checker Path.join(@app_root, "test/support/check_commonplace_refs.exs")

  test "the real yelixer tree has no executable parent-application references" do
    {output, status} = System.cmd("elixir", [@checker, @app_root], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "yelixer boundary check passed"
  end

  test "a parent-application alias in a temporary tree fails the checker" do
    temp_root =
      Path.join(
        System.tmp_dir!(),
        "yelixer-boundary-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(temp_root) end)

    for directory <- ["lib", "test"] do
      source = Path.join(@app_root, directory)
      destination = Path.join(temp_root, directory)
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(source, destination)
    end

    tamper_path = Path.join([temp_root, "lib", "tamper.ex"])

    parent_app = "Common" <> "place"

    File.write!(
      tamper_path,
      "defmodule Yelixer.Tamper do\n  alias #{parent_app}.Foo\nend\n"
    )

    {output, status} = System.cmd("elixir", [@checker, temp_root], stderr_to_stdout: true)

    if System.get_env("SHOW_YELIXER_BOUNDARY_TAMPER") == "1", do: IO.write(output)

    assert status == 1
    assert output =~ "yelixer boundary check failed"
    assert output =~ "tamper.ex:2:alias #{parent_app}.Foo"
  end
end
