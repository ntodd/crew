File.rm_rf!(Path.expand("../tmp/test-data/vms", __DIR__))
# :real_image prepares a real guest image (CREW_REAL_IMAGE_DIR): minutes, and 5 GB.
exclude = if match?({:unix, :darwin}, :os.type()), do: [:vz], else: [:vz, :darwin]
ExUnit.start(capture_log: true, exclude: [:real_image | exclude])
