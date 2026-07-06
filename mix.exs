defmodule Yelixer.MixProject do
  use Mix.Project

  def project do
    [
      app: :yelixer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:test]},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"}
    ]
  end
end
