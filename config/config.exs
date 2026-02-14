import Config

# Default configuration for KoboEink
#
# All values here match the stock Kobo Clara Colour partition layout.
# Override in your Nerves project's config as needed.

# config :kobo_eink,
#   kobo_partition: "/dev/mmcblk0p10",
#   init_bin_partition: "/dev/mmcblk0p8",
#   init_bin_mount: "/data/init_bin",
#   marker_file: "/var/lib/kobo-eink-copied",
#   partition_wait_timeout: 30_000,
#   mount_retries: 10,
#   mount_retry_delay: 1_000,
#   mdpd_init_delay: 500
