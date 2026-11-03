File.rm_rf!(Path.expand("../tmp/test-data/vms", __DIR__))
ExUnit.start(capture_log: true)
