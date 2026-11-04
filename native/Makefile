# Go code under native/ (§4, §20.1). One module, every dependency vendored:
# builds never touch the network.
#
#   make            build and ad-hoc sign crew-vz (VZ refuses unsigned binaries)
#   make hostvm-dev a Flatcar host VM with nested virtualization, for development
#   make test vet   unit tests and vet
#   make guest      build the integration-test guest (Docker) into ../tmp/crew-vz-guest
#   make integration  boot real VMs (macOS, needs the guest)
#   make vendor     refresh vendor/ after changing go.mod (needs the network)

GO ?= mise exec -- go
VERSION ?= dev
BIN := crew-vz/bin/crew-vz
GUEST := $(abspath ../tmp/crew-vz-guest)

export GOFLAGS := -mod=vendor
export GOPROXY := off

.PHONY: all crew-vz hostvm-dev test vet guest integration vendor clean

all: crew-vz

crew-vz:
	CGO_ENABLED=1 $(GO) build -trimpath -ldflags "-X main.version=$(VERSION)" -o $(BIN) ./crew-vz/cmd/crew-vz
	codesign --force -s - --entitlements entitlements.plist $(BIN)

# Development only: a Linux host VM with nested virtualization (e2e/hostvm).
hostvm-dev:
	CGO_ENABLED=1 $(GO) build -trimpath -o hostvm-dev/hostvm-dev ./hostvm-dev
	codesign --force -s - --entitlements entitlements.plist hostvm-dev/hostvm-dev

test:
	$(GO) test ./...

vet:
	$(GO) vet ./...

guest:
	GO="$(GO)" crew-vz/testdata/build-guest.sh $(GUEST)

integration: crew-vz
	CREW_VZ_BIN=$(abspath $(BIN)) CREW_VZ_GUEST=$(GUEST) \
		$(GO) test -tags integration -count=1 -timeout 30m -v ./crew-vz/integration/

vendor:
	GOFLAGS= GOPROXY=https://proxy.golang.org,direct $(GO) mod tidy
	GOFLAGS= GOPROXY=https://proxy.golang.org,direct $(GO) mod vendor

clean:
	rm -rf crew-vz/bin
