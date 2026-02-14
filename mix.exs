defmodule KoboEink.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Spin42/ex_kobo_eink"

  def project do
    [
      app: :kobo_eink,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KoboEink.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "KoboEink",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp description do
    "Initializes Kobo e-ink display hardware by extracting proprietary binaries " <>
      "from stock Kobo system partitions and starting required services (mdpd, " <>
      "nvram_daemon, pickel) so that FBInk/fbink_nif can drive the display."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
