File.rm_rf!(Path.expand("../tmp/test-data/vms", __DIR__))
# The agent started before that: what its janitor found there is gone.
CrewAgent.VMs.Cleanup.reset()
# :real_image prepares a real guest image (CREW_REAL_IMAGE_DIR): minutes, and 5 GB.
# :kvm boots real Firecracker VMs (native/crew-vmctl/kvm/run.sh sets the host up).
exclude = if match?({:unix, :darwin}, :os.type()), do: [:vz], else: [:vz, :darwin]
ExUnit.start(capture_log: true, exclude: [:real_image, :kvm | exclude])
