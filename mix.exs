defmodule HordeTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :horde_test,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        elixirtrader: [
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:runtime_tools, :logger, :observer, :wx],
      mod: {HordeTest.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:horde,"~> 0.6.0"},
#      {:delta_crdt,"~> 0.5.5"},
      {:libcluster, "~> 3.1"}
    ]
  end
end
