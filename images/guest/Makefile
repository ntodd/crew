# The job VM guest image (docs/crew_spec.md §13.1). Every step runs in
# Docker (see build.sh); the manifest tools need Elixir (tools/).
#
#   make                build, check, sign with the test key, verify
#   make kernel         fetch and verify the kernel tarball, build Image + modules
#   make kernel-config  regenerate kernel/$(ARCH).config after editing the fragment
#   make kernel-check   moby's check-config.sh and the Crew list, on the config
#   make rootfs         the root filesystem, out/$(ARCH)/rootfs.ext4
#   make artifacts      out/$(ARCH)/release/: .kernel, .rootfs.ext4.zst,
#                       .manifest.json, .manifest.sig (SIGN=test|release|none)
#   make check          the checks' and tools' own tests
#   make lock           re-resolve packages.lock for $(ARCH) (then review the diff)
#   make smoke          boot the built image on this Mac through crew-vz (macOS only)
#
# Variables: ARCH (arm64; x64 once kernel/x64.fragment exists), VERSION
# (0.1.0-dev), MIX (how to run mix), SIGN, PUBLIC_KEY.

ARCH ?= arm64
VERSION ?= 0.1.0-dev
MIX ?= $(if $(shell command -v mise 2>/dev/null),mise exec -- mix,mix)
export ARCH VERSION MIX SIGN PUBLIC_KEY

OUT := out/$(ARCH)
CREW_VZ := ../../native/crew-vz/bin/crew-vz

.PHONY: all builder kernel-config kernel kernel-check kernel-check-test rootfs lock \
	artifacts check conformance-test tools tools-test smoke clean

all: kernel kernel-check rootfs artifacts

builder kernel-config kernel kernel-check kernel-check-test rootfs lock:
	./build.sh $@

artifacts: tools
	./build.sh artifacts

check: kernel-check kernel-check-test tools-test conformance-test

# The conformance check's input handling (bash and jq, any OS).
conformance-test:
	conformance/check_test.sh

tools:
	cd tools && $(MIX) deps.get --check-locked >/dev/null && $(MIX) compile --warnings-as-errors

tools-test: tools
	cd tools && $(MIX) test

# The image as a box will run it: crew-vz daemon, a fake guest API on the
# VM's guest.sock. Needs `make -C ../../native` (a signed crew-vz).
smoke: tools
	cd tools && $(MIX) crew_image.smoke --crew-vz $(abspath $(CREW_VZ)) \
		--kernel $(abspath $(OUT)/kernel/Image) --rootfs $(abspath $(OUT)/rootfs.ext4) $(SMOKE_ARGS)

clean:
	rm -rf out work
