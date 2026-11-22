defmodule Robo.MixProject do
  use Mix.Project

  def project do
    [
      app: :robo,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: [],
      aliases: [test: "test --no-start"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Robo.Application, []}]
  end
end
