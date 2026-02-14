defmodule KoboEink do
  @moduledoc """
  Initializes Kobo e-ink display hardware for use with FBInk/fbink_nif.

  On Kobo e-readers (specifically the Clara Colour with MT8512/MT8113 SoC),
  the e-ink display requires proprietary binaries from the stock Kobo system
  partition to function. This library handles:

  1. Extracting proprietary binaries (`mdpd`, `nvram_daemon`, `pickel`,
     `ntx_check_regal_dev.sh`, nvram libraries) from the stock Kobo root
     partition (`/dev/mmcblk0p10`) at first boot.

  2. Mounting the init_bin partition (`/dev/mmcblk0p8`) which contains
     display initialization data needed at runtime.

  3. Starting the required services in the correct order:
     - `ntx_check_regal_dev.sh` (REGAL waveform device setup)
     - `mdpd` (MediaTek Display Processing Daemon)
     - `nvram_daemon` (NVRAM service)
     - `pickel init` (e-ink controller hardware initialization)

  After initialization completes, `/dev/fb0` is ready for use by FBInk
  and the `fbink_nif` Elixir bindings.

  ## Usage

  Add `kobo_eink` to your dependencies:

      {:kobo_eink, path: "../kobo_eink"}

  The application starts automatically via its OTP application callback.
  Subscribe to initialization events to know when the display is ready:

      KoboEink.subscribe()

      receive do
        {:kobo_eink, :ready} ->
          fd = FBInk.open()
          FBInk.init(fd, %FBInk.Config{})
          FBInk.print(fd, "Hello!", %FBInk.Config{})

        {:kobo_eink, {:error, reason}} ->
          Logger.error("Display init failed: \#{inspect(reason)}")
      end

  ## Events

  Subscribers receive `{:kobo_eink, event}` messages where event is one of:

  - `:copying_firmware` - extracting binaries from stock partition
  - `:firmware_copied` - extraction complete
  - `:starting_services` - starting mdpd, nvram_daemon, pickel
  - `:services_started` - all services running
  - `:ready` - display fully initialized, fbink_nif can be used
  - `{:error, reason}` - initialization failed

  ## Configuration

  All options can be set via application config:

      config :kobo_eink,
        kobo_partition: "/dev/mmcblk0p10",
        init_bin_partition: "/dev/mmcblk0p8",
        init_bin_mount: "/data/init_bin",
        marker_file: "/var/lib/kobo-eink-copied",
        partition_wait_timeout: 30_000,
        mount_retries: 10
  """

  @doc """
  Subscribes the calling process to initialization events.

  The subscriber receives `{:kobo_eink, event}` messages as the init
  progresses. If initialization has already completed (or failed), the
  current state is sent immediately.

  See module docs for the full list of events.
  """
  @spec subscribe() :: :ok
  def subscribe do
    KoboEink.Init.subscribe()
  end

  @doc """
  Unsubscribes the calling process from initialization events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    KoboEink.Init.unsubscribe()
  end

  @doc """
  Returns the current initialization status.

  Returns one of:
  - `:ready` - e-ink display is initialized and ready for FBInk
  - `:initializing` - initialization hasn't started copying yet
  - `:copying_firmware` - extracting binaries from stock partition
  - `:starting_services` - starting display services
  - `{:error, reason}` - initialization failed
  """
  @spec status() :: KoboEink.Init.status()
  def status do
    KoboEink.Init.status()
  end

  @doc """
  Stops all e-ink services (mdpd, nvram_daemon) and unmounts partitions.
  """
  @spec stop_services() :: :ok
  def stop_services do
    KoboEink.Services.stop_all()
  end
end
