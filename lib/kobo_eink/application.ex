defmodule KoboEink.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KoboEink.Init
    ]

    opts = [strategy: :one_for_one, name: KoboEink.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
