defmodule KoboEink.Partition do
  @moduledoc """
  Handles waiting for block devices and mounting/unmounting partitions.

  Provides retry logic for both device availability and mount operations,
  since on early boot the eMMC partitions may not yet be enumerated by the kernel.
  """

  require Logger

  @doc """
  Waits for a block device to become available.

  Polls for the device at 1-second intervals up to `timeout_ms` milliseconds.
  Returns `:ok` once the device exists, or `{:error, :timeout}`.
  """
  @spec wait_for_device(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_device(device_path, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_device(device_path, deadline)
  end

  defp do_wait_for_device(device_path, deadline) do
    if block_device?(device_path) do
      Logger.info("[KoboEink] Block device #{device_path} is available")
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        Logger.error("[KoboEink] Timeout waiting for #{device_path}")
        {:error, :timeout}
      else
        Logger.debug("[KoboEink] Waiting for #{device_path}... (#{div(remaining, 1000)}s left)")
        Process.sleep(1_000)
        do_wait_for_device(device_path, deadline)
      end
    end
  end

  @doc """
  Mounts a partition read-only at the given mount point, with retries.

  Creates the mount point directory if it does not exist. Returns `:ok` on
  success or `{:error, reason}` on failure after all retries are exhausted.
  """
  @spec mount_readonly(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def mount_readonly(device_path, mount_point, retries \\ 10, retry_delay_ms \\ 1_000) do
    File.mkdir_p!(mount_point)
    do_mount(device_path, mount_point, retries, retry_delay_ms)
  end

  defp do_mount(device_path, mount_point, retries_left, retry_delay_ms) do
    case System.cmd("mount", ["-o", "ro", device_path, mount_point], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("[KoboEink] Mounted #{device_path} at #{mount_point}")
        :ok

      {output, _exit_code} when retries_left > 0 ->
        Logger.warning(
          "[KoboEink] Mount #{device_path} failed (#{retries_left} retries left): #{String.trim(output)}"
        )

        Process.sleep(retry_delay_ms)
        do_mount(device_path, mount_point, retries_left - 1, retry_delay_ms)

      {output, exit_code} ->
        Logger.error(
          "[KoboEink] Failed to mount #{device_path} after all retries: exit=#{exit_code} #{String.trim(output)}"
        )

        {:error, {:mount_failed, device_path, exit_code}}
    end
  end

  @doc """
  Unmounts a mount point if it is currently mounted.
  """
  @spec unmount(String.t()) :: :ok | {:error, term()}
  def unmount(mount_point) do
    if mounted?(mount_point) do
      case System.cmd("umount", [mount_point], stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("[KoboEink] Unmounted #{mount_point}")
          :ok

        {output, exit_code} ->
          Logger.error(
            "[KoboEink] Failed to unmount #{mount_point}: exit=#{exit_code} #{String.trim(output)}"
          )

          {:error, {:unmount_failed, mount_point, exit_code}}
      end
    else
      :ok
    end
  end

  @doc """
  Checks if a path is a mount point by reading /proc/mounts.
  """
  @spec mounted?(String.t()) :: boolean()
  def mounted?(path) do
    case File.read("/proc/mounts") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.any?(fn line ->
          case String.split(line, " ") do
            [_device, mount_point | _rest] -> mount_point == path
            _ -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  @doc """
  Checks if a path is a block device.
  """
  @spec block_device?(String.t()) :: boolean()
  def block_device?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :device}} -> true
      _ -> false
    end
  end
end
