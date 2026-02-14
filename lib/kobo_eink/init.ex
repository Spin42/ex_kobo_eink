defmodule KoboEink.Init do
  @moduledoc """
  GenServer that manages the e-ink display initialization lifecycle.

  On startup, runs the full initialization sequence asynchronously:
  1. Copy proprietary binaries from stock Kobo partition (first boot only)
  2. Start all required e-ink services

  Subscribers receive messages as state transitions happen:

      KoboEink.subscribe()
      # receive do
      #   {:kobo_eink, :firmware_copied} -> ...
      #   {:kobo_eink, :services_started} -> ...
      #   {:kobo_eink, :ready} -> ...
      #   {:kobo_eink, {:error, reason}} -> ...
      # end
  """

  use GenServer

  require Logger

  @type status ::
          :initializing | :copying_firmware | :starting_services | :ready | {:error, term()}

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current initialization status.
  """
  @spec status() :: status()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Subscribes the calling process to initialization events.

  The subscriber will receive messages of the form `{:kobo_eink, event}` where
  event is one of:

  - `:copying_firmware` - firmware extraction from stock partition has started
  - `:firmware_copied` - firmware extraction completed successfully
  - `:starting_services` - service startup sequence has started
  - `:services_started` - all services started successfully
  - `:ready` - display is fully initialized, fbink_nif can be used
  - `{:error, reason}` - initialization failed

  If initialization has already completed (or failed) by the time `subscribe/0`
  is called, the subscriber immediately receives the current state.
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribes the calling process from initialization events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    state = %{status: :initializing, subscribers: MapSet.new()}
    send(self(), :initialize)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)

    # If we're already past initializing, send the current state immediately
    case state.status do
      :initializing -> :ok
      terminal -> send(pid, {:kobo_eink, terminal})
    end

    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(:initialize, state) do
    new_status = do_initialize(state.subscribers)
    {:noreply, %{state | status: new_status}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # -- Private --

  defp do_initialize(subscribers) do
    Logger.info("[KoboEink] Starting e-ink display initialization...")

    broadcast(subscribers, :copying_firmware)

    case KoboEink.Firmware.ensure_copied() do
      :ok ->
        broadcast(subscribers, :firmware_copied)
        broadcast(subscribers, :starting_services)

        case KoboEink.Services.start_all() do
          :ok ->
            broadcast(subscribers, :services_started)
            broadcast(subscribers, :ready)
            Logger.info("[KoboEink] E-ink display is ready")
            :ready

          {:error, reason} = error ->
            broadcast(subscribers, error)
            Logger.error("[KoboEink] Service startup failed: #{inspect(reason)}")
            error
        end

      {:error, reason} = error ->
        broadcast(subscribers, error)
        Logger.error("[KoboEink] Firmware copy failed: #{inspect(reason)}")
        error
    end
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:kobo_eink, event})
    end)
  end
end
