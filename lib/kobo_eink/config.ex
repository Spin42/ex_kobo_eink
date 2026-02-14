defmodule KoboEink.Config do
  @moduledoc """
  Configuration for the Kobo e-ink initialization.

  All values can be overridden via application config under the `:kobo_eink` key.
  """

  @doc """
  Returns the stock Kobo root partition device path.

  This partition contains the proprietary binaries needed for e-ink initialization.
  """
  def kobo_partition do
    Application.get_env(:kobo_eink, :kobo_partition, "/dev/mmcblk0p10")
  end

  @doc """
  Returns the init_bin partition device path.

  This partition contains initialization data required at runtime by the
  display subsystem.
  """
  def init_bin_partition do
    Application.get_env(:kobo_eink, :init_bin_partition, "/dev/mmcblk0p8")
  end

  @doc """
  Returns the mount point for the init_bin partition.
  """
  def init_bin_mount do
    Application.get_env(:kobo_eink, :init_bin_mount, "/data/init_bin")
  end

  @doc """
  Returns the path to the marker file that tracks whether binaries have been copied.
  """
  def marker_file do
    Application.get_env(:kobo_eink, :marker_file, "/var/lib/kobo-eink-copied")
  end

  @doc """
  Returns the timeout in milliseconds to wait for a partition device to appear.
  """
  def partition_wait_timeout do
    Application.get_env(:kobo_eink, :partition_wait_timeout, 30_000)
  end

  @doc """
  Returns the number of mount retries before giving up.
  """
  def mount_retries do
    Application.get_env(:kobo_eink, :mount_retries, 10)
  end

  @doc """
  Returns the delay in ms between mount retry attempts.
  """
  def mount_retry_delay do
    Application.get_env(:kobo_eink, :mount_retry_delay, 1_000)
  end

  @doc """
  Returns the delay in ms to wait for mdpd to initialize after starting.
  """
  def mdpd_init_delay do
    Application.get_env(:kobo_eink, :mdpd_init_delay, 500)
  end

  @doc """
  Returns the manifest of files to copy from the stock Kobo partition.

  Each entry is `{source_path_relative_to_mount, destination_path, permissions}`.
  """
  def firmware_manifest do
    Application.get_env(:kobo_eink, :firmware_manifest, default_firmware_manifest())
  end

  defp default_firmware_manifest do
    [
      # mdpd - MediaTek Display Processing Daemon
      {"usr/bin/mdpd", "/usr/bin/mdpd", 0o755},
      # nvram_daemon - NVRAM service
      {"sbin/nvram_daemon", "/sbin/nvram_daemon", 0o755},
      # pickel - Kobo e-ink controller initialization
      {"usr/local/Kobo/pickel", "/usr/local/Kobo/pickel", 0o755},
      # ntx_check_regal_dev.sh - REGAL waveform device setup
      {"etc/init.d/ntx_check_regal_dev.sh", "/usr/libexec/ntx_check_regal_dev.sh", 0o755},
      # NVRAM libraries
      {"lib/libnvram/libnvram.so", "/lib/libnvram/libnvram.so", 0o755},
      {"lib/libnvram/libnvram_custom.so", "/lib/libnvram/libnvram_custom.so", 0o755}
    ]
  end
end
