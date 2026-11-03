File.rm_rf!(Path.expand("../tmp/test-data/vms", __DIR__))
exclude = if match?({:unix, :darwin}, :os.type()), do: [:vz], else: [:vz, :darwin]
ExUnit.start(capture_log: true, exclude: exclude)
