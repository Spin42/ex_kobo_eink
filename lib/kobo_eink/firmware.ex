defmodule KoboEink.Firmware do
  @moduledoc """
  Extracts proprietary e-ink display binaries from the stock Kobo system partition.

  On first boot, mounts the stock Kobo root partition (typically `/dev/mmcblk0p10`)
  and copies the following proprietary binaries needed for e-ink display operation:

  - `mdpd` - MediaTek Display Processing Daemon
  - `nvram_daemon` - NVRAM service daemon
  - `pickel` - Kobo e-ink controller hardware initialization tool
  - `ntx_check_regal_dev.sh` - Netronix REGAL waveform device setup script
  - `libnvram.so` / `libnvram_custom.so` - NVRAM access libraries

  A marker file tracks whether the copy has already been performed, so this
  operation is skipped on subsequent boots.
  """

  require Logger

  alias KoboEink.{Config, Partition}

  @doc """
  Ensures all proprietary firmware binaries are present on the filesystem.

  If the marker file exists, this is a no-op. Otherwise, mounts the stock
  Kobo partition, copies all binaries per the firmware manifest, unmounts,
  and creates the marker file.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec ensure_copied() :: :ok | {:error, term()}
  def ensure_copied do
    marker = Config.marker_file()

    if File.exists?(marker) do
      Logger.info("[KoboEink] Firmware already copied (marker exists: #{marker})")
      :ok
    else
      copy_firmware()
    end
  end

  @doc """
  Returns true if the firmware has already been copied (marker file exists).
  """
  @spec copied?() :: boolean()
  def copied? do
    File.exists?(Config.marker_file())
  end

  defp copy_firmware do
    kobo_partition = Config.kobo_partition()
    mount_point = "/tmp/kobo-eink-mount"
    timeout = Config.partition_wait_timeout()
    retries = Config.mount_retries()
    retry_delay = Config.mount_retry_delay()

    Logger.info("[KoboEink] Copying e-ink firmware from #{kobo_partition}...")

    with :ok <- Partition.wait_for_device(kobo_partition, timeout),
         :ok <- Partition.mount_readonly(kobo_partition, mount_point, retries, retry_delay),
         :ok <- copy_all_files(mount_point),
         :ok <- Partition.unmount(mount_point) do
      # Clean up mount point
      File.rmdir(mount_point)

      # Create marker file
      marker = Config.marker_file()
      marker |> Path.dirname() |> File.mkdir_p!()
      File.write!(marker, "")

      Logger.info("[KoboEink] Firmware copy complete")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[KoboEink] Firmware copy failed: #{inspect(reason)}")
        # Attempt cleanup
        Partition.unmount(mount_point)
        File.rmdir(mount_point)
        error
    end
  end

  defp copy_all_files(mount_point) do
    manifest = Config.firmware_manifest()

    results =
      Enum.map(manifest, fn {source_rel, dest, permissions} ->
        source = Path.join(mount_point, source_rel)
        copy_file(source, dest, permissions)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      # Log errors but don't fail entirely - some files may be optional
      # on different hardware revisions
      Enum.each(errors, fn {:error, reason} ->
        Logger.warning("[KoboEink] File copy issue: #{inspect(reason)}")
      end)

      # Check if critical files were copied
      critical_files = ["/usr/bin/mdpd", "/usr/local/Kobo/pickel"]

      missing_critical =
        Enum.filter(critical_files, fn path -> not File.exists?(path) end)

      if missing_critical == [] do
        Logger.info("[KoboEink] All critical binaries present, continuing despite warnings")
        :ok
      else
        {:error, {:missing_critical_files, missing_critical}}
      end
    end
  end

  defp copy_file(source, dest, permissions) do
    dest_dir = Path.dirname(dest)

    with :ok <- ensure_dir(dest_dir),
         {:ok, _} <- do_copy(source, dest),
         :ok <- File.chmod(dest, permissions) do
      Logger.info("[KoboEink] Copied #{Path.basename(source)} -> #{dest}")
      :ok
    else
      {:error, reason} ->
        Logger.warning("[KoboEink] Failed to copy #{source} -> #{dest}: #{inspect(reason)}")
        {:error, {:copy_failed, source, dest, reason}}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp do_copy(source, dest) do
    case File.cp(source, dest) do
      :ok -> {:ok, dest}
      {:error, reason} -> {:error, reason}
    end
  end
end
