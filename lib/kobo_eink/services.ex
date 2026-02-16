defmodule KoboEink.Services do
  @moduledoc """
  Manages the proprietary e-ink display services.

  Handles starting and stopping the daemons and initialization steps
  required for the Kobo e-ink display to function:

  - **init_bin mount** - Mount the init_bin partition containing display init data
  - **REGAL device check** - Ensure REGAL waveform device nodes exist in `/dev`
  - **mdpd** - MediaTek Display Processing Daemon for hardware-accelerated display updates
  - **nvram_daemon** - NVRAM service for hardware calibration/config storage
  - **pickel init** - Hardware-level e-ink controller initialization
  """

  require Logger

  alias KoboEink.{Config, Partition}

  @doc """
  Runs the full e-ink service startup sequence.

  This must be called after `KoboEink.Firmware.ensure_copied/0` has completed.
  The sequence mirrors the `start_eink_services` function in the buildroot
  S20kobo-eink init script.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec start_all() :: :ok | {:error, term()}
  def start_all do
    Logger.info("[KoboEink] Starting e-ink display services...")

    with :ok <- mount_init_bin(),
         :ok <- run_regal_check(),
         :ok <- start_mdpd(),
         :ok <- start_nvram_daemon(),
         :ok <- run_pickel_init() do
      Logger.info("[KoboEink] E-ink display initialization complete")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[KoboEink] Service startup failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops all e-ink services and unmounts the init_bin partition.
  """
  @spec stop_all() :: :ok
  def stop_all do
    Logger.info("[KoboEink] Stopping e-ink display services...")

    kill_daemon("mdpd")
    kill_daemon("nvram_daemon")

    Partition.unmount(Config.init_bin_mount())

    Logger.info("[KoboEink] E-ink services stopped")
    :ok
  end

  # -- Individual service management --

  @doc """
  Mounts the init_bin partition read-only.

  The init_bin partition (`/dev/mmcblk0p8`) contains initialization data
  required by the display subsystem at runtime.
  """
  @spec mount_init_bin() :: :ok | {:error, term()}
  def mount_init_bin do
    partition = Config.init_bin_partition()
    mount_point = Config.init_bin_mount()

    if Partition.mounted?(mount_point) do
      Logger.info("[KoboEink] init_bin already mounted at #{mount_point}")
      :ok
    else
      if Partition.block_device?(partition) do
        case Partition.mount_readonly(partition, mount_point, 3, 1_000) do
          :ok ->
            # mount is synchronous - the filesystem is ready when it returns.
            # No need to sync after a read-only mount.
            :ok

          {:error, _} = error ->
            Logger.warning("[KoboEink] Failed to mount init_bin partition (non-fatal)")
            error
        end
      else
        Logger.warning("[KoboEink] init_bin partition #{partition} not found (non-fatal)")
        {:error, :device_not_found}
      end
    end
  end

  @regal_sysfs "/sys/class/regal_class"
  @regal_devices ~w(regal_wb regal_tmp regal_img regal_cinfo regal_waveform)

  @doc """
  Ensures REGAL waveform device nodes exist in `/dev`.

  Reads major:minor numbers from sysfs and creates character device nodes
  via `mknod` if they don't already exist. This is a pure Elixir replacement
  for the stock `ntx_check_regal_dev.sh` script, avoiding dependencies on
  `awk` and other shell utilities not present in Nerves.

  Non-fatal: the display may still work without REGAL optimization.
  """
  @spec run_regal_check() :: :ok | {:error, term()}
  def run_regal_check do
    if File.dir?(@regal_sysfs) do
      Logger.info("[KoboEink] Checking REGAL device nodes...")

      Enum.each(@regal_devices, fn dev_name ->
        ensure_regal_device(dev_name)
      end)

      :ok
    else
      Logger.warning(
        "[KoboEink] #{@regal_sysfs} not found - REGAL not supported on this hardware (non-fatal)"
      )

      :ok
    end
  end

  defp ensure_regal_device(dev_name) do
    sysfs_dev = Path.join([@regal_sysfs, dev_name, "dev"])
    dev_path = Path.join("/dev", dev_name)

    cond do
      not File.exists?(sysfs_dev) ->
        Logger.warning("[KoboEink] REGAL sysfs entry for #{dev_name} not found, skipping")

      File.exists?(dev_path) ->
        Logger.debug("[KoboEink] REGAL device #{dev_path} already exists")

      true ->
        case read_major_minor(sysfs_dev) do
          {:ok, major, minor} ->
            create_device_node(dev_path, major, minor)

          {:error, reason} ->
            Logger.warning(
              "[KoboEink] Failed to read major:minor for #{dev_name}: #{inspect(reason)}"
            )
        end
    end
  end

  defp read_major_minor(sysfs_dev_path) do
    case File.read(sysfs_dev_path) do
      {:ok, content} ->
        case content |> String.trim() |> String.split(":") do
          [major_str, minor_str] ->
            with {major, ""} <- Integer.parse(major_str),
                 {minor, ""} <- Integer.parse(minor_str) do
              {:ok, major, minor}
            else
              _ -> {:error, {:parse_failed, String.trim(content)}}
            end

          _ ->
            {:error, {:unexpected_format, String.trim(content)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_device_node(dev_path, major, minor) do
    Logger.info("[KoboEink] Creating REGAL device node #{dev_path} (#{major}:#{minor})")

    case System.cmd("mknod", [dev_path, "c", to_string(major), to_string(minor)],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("[KoboEink] Created #{dev_path}")

      {output, exit_code} ->
        Logger.warning(
          "[KoboEink] Failed to create #{dev_path}: exit=#{exit_code} #{String.trim(output)}"
        )
    end
  end

  @doc """
  Starts the mdpd (MediaTek Display Processing) daemon.

  mdpd manages the hardware-accelerated MDP pipeline for e-ink display updates
  on MT8512/MT8113 SoCs. Waits briefly after starting for it to initialize.
  """
  @spec start_mdpd() :: :ok | {:error, term()}
  def start_mdpd do
    binary = "/usr/bin/mdpd"

    if File.exists?(binary) do
      if daemon_running?("mdpd") do
        Logger.info("[KoboEink] mdpd already running")
        :ok
      else
        Logger.info("[KoboEink] Starting mdpd daemon...")

        case start_daemon_via_sh(binary, ["-f"]) do
          :ok ->
            # Give mdpd time to initialize (matches the 0.5s sleep in the shell script)
            init_delay = Config.mdpd_init_delay()
            Logger.debug("[KoboEink] Waiting #{init_delay}ms for mdpd to initialize...")
            Process.sleep(init_delay)

            if daemon_running?("mdpd") do
              Logger.info("[KoboEink] mdpd started successfully")
              :ok
            else
              Logger.warning("[KoboEink] mdpd started but process not found (may have exited)")
              :ok
            end

          error ->
            error
        end
      end
    else
      Logger.error("[KoboEink] mdpd not found at #{binary}")
      {:error, {:not_found, binary}}
    end
  end

  @doc """
  Starts the nvram_daemon.

  Creates `/data/nvram` for NVRAM data storage.
  """
  @spec start_nvram_daemon() :: :ok | {:error, term()}
  def start_nvram_daemon do
    binary = "/sbin/nvram_daemon"

    if File.exists?(binary) do
      if daemon_running?("nvram_daemon") do
        Logger.info("[KoboEink] nvram_daemon already running")
        :ok
      else
        # Create nvram data directory
        File.mkdir_p!("/data/nvram")

        Logger.info("[KoboEink] Starting nvram_daemon...")

        start_daemon_via_sh(binary, [])
      end
    else
      Logger.warning("[KoboEink] nvram_daemon not found at #{binary} (non-fatal)")
      :ok
    end
  end

  @doc """
  Runs `pickel init` to perform hardware-level e-ink controller initialization.

  This is the final step that makes `/dev/fb0` ready for use by FBInk.
  """
  @spec run_pickel_init() :: :ok | {:error, term()}
  def run_pickel_init do
    binary = "/usr/local/Kobo/pickel"

    if File.exists?(binary) do
      Logger.info("[KoboEink] Running pickel init...")

      case System.cmd(binary, ["init"], stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("[KoboEink] pickel init completed successfully")

          unless output == "" do
            Logger.debug("[KoboEink] pickel output: #{String.trim(output)}")
          end

          :ok

        {output, exit_code} ->
          Logger.error(
            "[KoboEink] pickel init failed with exit code #{exit_code}: #{String.trim(output)}"
          )

          {:error, {:pickel_init_failed, exit_code}}
      end
    else
      Logger.error("[KoboEink] pickel not found at #{binary}")
      {:error, {:not_found, binary}}
    end
  end

  # -- Private helpers --

  defp start_daemon_via_sh(binary, args, env \\ []) do
    cmd_args = [binary | args]
    cmd_str = Enum.join(cmd_args, " ") <> " &"

    case System.cmd("sh", ["-c", cmd_str], stderr_to_stdout: true, env: env) do
      {_output, 0} ->
        # Brief pause for the daemon to start
        Process.sleep(200)
        Logger.info("[KoboEink] Started #{Path.basename(binary)} via sh")
        :ok

      {output, exit_code} ->
        Logger.error(
          "[KoboEink] Failed to start #{Path.basename(binary)}: exit=#{exit_code} #{String.trim(output)}"
        )

        {:error, {:start_failed, binary, exit_code}}
    end
  end

  defp kill_daemon(name) do
    case System.cmd("killall", [name], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("[KoboEink] Stopped #{name}")

      {_output, _} ->
        Logger.debug("[KoboEink] #{name} was not running")
    end
  end

  defp daemon_running?(name) do
    # Use /proc directly instead of `pidof` which isn't available on Nerves.
    # /proc/<pid>/comm contains the process name (truncated to 15 chars).
    Path.wildcard("/proc/[0-9]*/comm")
    |> Enum.any?(fn comm_path ->
      case File.read(comm_path) do
        {:ok, contents} -> String.trim(contents) == name
        {:error, _} -> false
      end
    end)
  end
end
