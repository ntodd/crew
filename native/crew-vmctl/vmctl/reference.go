package vmctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/ntodd/crew/native/crew-vmctl/etc"
	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// ReferenceOutput is what `crew-vmctl nft-reference` prints.
type ReferenceOutput struct {
	Nft    json.RawMessage `json:"nft"`
	Mangle string          `json:"mangle"`
}

// NftReference is `crew-vmctl nft-reference`, which nft-verify runs in a
// new network namespace: it loads etc/ there and lists it, as the box's
// own nft and iptables-nft print it. It refuses to run anywhere that
// already has tables, so it can never replace the box's own.
func NftReference(ctx context.Context, sys Sys, uplink string) (ReferenceOutput, error) {
	tables, err := sys.Run(ctx, nil, "nft", "list", "tables")
	if err != nil {
		return ReferenceOutput{}, err
	}
	if strings.TrimSpace(string(tables)) != "" {
		return ReferenceOutput{}, fmt.Errorf("nft-reference runs in a fresh network namespace, and this one has tables")
	}
	script, err := ruleset.LoadScript(etc.NftConf, uplink)
	if err != nil {
		return ReferenceOutput{}, err
	}
	if _, err := sys.Run(ctx, []byte(script), "nft", "-f", "-"); err != nil {
		return ReferenceOutput{}, err
	}
	if _, err := sys.Run(ctx, []byte(etc.ConnlimitRules), "iptables-nft-restore"); err != nil {
		return ReferenceOutput{}, err
	}
	nft, err := sys.Run(ctx, nil, "nft", "-j", "list", "table", "inet", "crew")
	if err != nil {
		return ReferenceOutput{}, err
	}
	mangle, err := sys.Run(ctx, nil, "iptables-nft-save", "-t", "mangle")
	if err != nil {
		return ReferenceOutput{}, err
	}
	return ReferenceOutput{Nft: nft, Mangle: string(mangle)}, nil
}
