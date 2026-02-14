# KoboEink

Elixir library that initializes the e-ink display on Kobo e-readers running
[Nerves](https://nerves-project.org/), so that
[fbink_nif](https://github.com/Spin42/fbink_nif) can drive the screen.

Kobo devices (tested on the Clara Colour, MT8512/MT8113 SoC) ship with
proprietary userspace binaries that must be running before the kernel's HWTCON
framebuffer is usable. Because these binaries live on the stock Kobo root
partition and cannot be redistributed, this library extracts them at first boot
and starts the required services in the correct order.

## What it does

1. **Extracts proprietary binaries** from the stock Kobo root partition
   (`/dev/mmcblk0p10`) on first boot:

   | Binary | Role |
   |---|---|
   | `mdpd` | MediaTek Display Processing Daemon |
   | `nvram_daemon` | NVRAM calibration/config service |
   | `pickel` | Kobo e-ink controller init tool |
   | `ntx_check_regal_dev.sh` | REGAL waveform device setup |
   | `libnvram.so`, `libnvram_custom.so` | NVRAM access libraries |

   A marker file prevents re-extraction on subsequent boots.

2. **Starts display services** in order:
   - Mounts the init\_bin partition (`/dev/mmcblk0p8` -> `/data/init_bin`)
   - Runs `ntx_check_regal_dev.sh`
   - Starts `mdpd`
   - Starts `nvram_daemon`
   - Runs `pickel init`

3. **Broadcasts events** so your application knows exactly when `/dev/fb0` is
   ready for FBInk.

## Installation

Add `kobo_eink` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:kobo_eink, github: "Spin42/ex_kobo_eink"}
  ]
end
```

## Usage

The application starts automatically. Subscribe to get notified when the
display is ready:

```elixir
defmodule MyApp.Display do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    KoboEink.subscribe()
    {:ok, :waiting}
  end

  @impl true
  def handle_info({:kobo_eink, :ready}, _state) do
    {:ok, fd} = FBInk.open()
    FBInk.init(fd, %FBInk.Config{})
    FBInk.print(fd, "Hello from Nerves!", %FBInk.Config{})
    {:noreply, {:ready, fd}}
  end

  def handle_info({:kobo_eink, {:error, reason}}, _state) do
    require Logger
    Logger.error("E-ink init failed: #{inspect(reason)}")
    {:noreply, {:error, reason}}
  end

  def handle_info({:kobo_eink, phase}, state) do
    require Logger
    Logger.info("E-ink init phase: #{phase}")
    {:noreply, state}
  end
end
```

### Events

Subscribers receive `{:kobo_eink, event}` messages:

| Event | Meaning |
|---|---|
| `:copying_firmware` | Extracting binaries from stock partition |
| `:firmware_copied` | Extraction complete |
| `:starting_services` | Starting mdpd, nvram\_daemon, pickel |
| `:services_started` | All services running |
| `:ready` | `/dev/fb0` is ready for fbink\_nif |
| `{:error, reason}` | Initialization failed |

If you subscribe after initialization has already completed (or failed), you
immediately receive the current terminal state.

### One-off status check

```elixir
KoboEink.status()
# :ready | :initializing | :copying_firmware | :starting_services | {:error, reason}
```

### Stopping services

```elixir
KoboEink.stop_services()
```

## Configuration

All values have sensible defaults for the Kobo Clara Colour. Override in your
`config.exs` if your device differs:

```elixir
config :kobo_eink,
  kobo_partition: "/dev/mmcblk0p10",
  init_bin_partition: "/dev/mmcblk0p8",
  init_bin_mount: "/data/init_bin",
  marker_file: "/var/lib/kobo-eink-copied",
  partition_wait_timeout: 30_000,
  mount_retries: 10,
  mount_retry_delay: 1_000,
  mdpd_init_delay: 500
```

The firmware manifest (which files to extract and where to place them) can also
be overridden:

```elixir
config :kobo_eink,
  firmware_manifest: [
    {"usr/bin/mdpd", "/usr/bin/mdpd", 0o755},
    {"sbin/nvram_daemon", "/sbin/nvram_daemon", 0o755},
    # ...
  ]
```

## How it works

This library is the Elixir/Nerves equivalent of the `S20kobo-eink` init script
from [buildroot-kobo](https://github.com/Spin42/buildroot-kobo). The Kobo Clara
Colour uses a MediaTek MT8512 SoC with a kernel-level HWTCON driver that
provides `/dev/fb0`. However, the framebuffer isn't usable until several
proprietary userspace daemons are running and `pickel init` has configured the
e-ink controller hardware.

Because the device uses Secure Boot, these proprietary binaries can't be freely
redistributed. Instead, they're extracted at first boot from the stock Kobo root
filesystem that still lives on the device's eMMC.

The initialization sequence:

```
Kernel (HWTCON + PMIC drivers built-in)
  |
  +-- /dev/fb0 exists but is not yet usable
  |
KoboEink.Init GenServer starts
  |
  +-- [first boot] Mount /dev/mmcblk0p10, extract binaries
  |
  +-- Mount /dev/mmcblk0p8 -> /data/init_bin
  +-- ntx_check_regal_dev.sh   (REGAL waveform setup)
  +-- mdpd -f                  (display processing daemon)
  +-- nvram_daemon              (NVRAM service)
  +-- pickel init               (e-ink hardware init)
  |
  +-- :ready -- /dev/fb0 is now usable by FBInk/fbink_nif
```

## License

MIT License. See [LICENSE](LICENSE) for details.
