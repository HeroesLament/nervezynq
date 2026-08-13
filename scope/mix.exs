defmodule NzScope.MixProject do
  use Mix.Project

  def project do
    [
      app: :nz_scope,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {NzScope.Application, []},
      extra_applications: [:logger, :wx]
    ]
  end

  defp deps do
    [
      # Path dep, not hex: the GLCanvas surface this app leans on is the one
      # in the working tree next door.
      {:wx_mvu, path: "../../wx_mvu"}
    ]
  end
end
