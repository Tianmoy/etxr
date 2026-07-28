package dataplane

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestScrapeUsageAggregatesAndResets(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	usagePath := filepath.Join(directory, "usage.json")
	state := map[string]interface{}{
		"users": []map[string]interface{}{{
			"name": "alice", "uuid": "uuid-1", "usage_epoch": "epoch-1",
		}},
		"data_plane": map[string]interface{}{"xray_api_port": 19191},
	}
	writeTestJSON(t, statePath, state)

	calls := 0
	query := func(_ context.Context, binary string, port int) (map[string]int64, bool) {
		calls++
		if binary != "fake-xray" || port != 19191 {
			t.Fatalf("unexpected query %q port %d", binary, port)
		}
		return map[string]int64{
			"user>>>alice@hk>>>traffic>>>uplink":     1000,
			"user>>>alice@hy2>>>traffic>>>downlink":  2000,
			"user>>>relay@worker>>>traffic>>>uplink": 9999,
			"user>>>alice@hk>>>traffic>>>invalid":    500,
		}, true
	}
	options := MeterOptions{
		StatePath: statePath,
		UsagePath: usagePath,
		XrayBin:   "fake-xray",
		Interval:  time.Second,
		Once:      true,
	}
	if err := scrapeUsage(context.Background(), options, query); err != nil {
		t.Fatal(err)
	}
	ledger := readTestLedger(t, usagePath)
	if calls != 1 || ledger.Users["alice"].Uplink != 1000 ||
		ledger.Users["alice"].Downlink != 2000 {
		t.Fatalf("unexpected ledger: %#v", ledger)
	}
	if _, exists := ledger.Users["relay"]; exists {
		t.Fatal("relay identity was included")
	}

	state["users"].([]map[string]interface{})[0]["usage_epoch"] = "epoch-2"
	writeTestJSON(t, statePath, state)
	if err := scrapeUsage(context.Background(), options, query); err != nil {
		t.Fatal(err)
	}
	reset := readTestLedger(t, usagePath)
	if reset.Users["alice"].UsageEpoch != "epoch-2" ||
		reset.Users["alice"].Uplink != 1000 ||
		reset.Users["alice"].Downlink != 2000 {
		t.Fatalf("usage epoch did not reset: %#v", reset.Users["alice"])
	}
}

func TestScrapeUsagePreservesLedgerWhenXrayFails(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	usagePath := filepath.Join(directory, "usage.json")
	writeTestJSON(t, statePath, map[string]interface{}{
		"users": []map[string]interface{}{{
			"name": "alice", "uuid": "uuid-1", "usage_epoch": "epoch-1",
		}},
	})
	writeTestJSON(t, usagePath, usageLedger{
		Schema: 1,
		Raw:    map[string]map[string]int64{"xray": {"old": 1}},
		Users: map[string]usageLedgerUser{
			"alice": {UUID: "uuid-1", UsageEpoch: "epoch-1", Uplink: 12, Downlink: 34},
		},
	})
	options := MeterOptions{
		StatePath: statePath, UsagePath: usagePath, XrayBin: "missing",
		Interval: time.Second, Once: true,
	}
	if err := scrapeUsage(
		context.Background(),
		options,
		func(context.Context, string, int) (map[string]int64, bool) {
			return nil, false
		},
	); err != nil {
		t.Fatal(err)
	}
	ledger := readTestLedger(t, usagePath)
	if ledger.Users["alice"].Uplink != 12 || ledger.Users["alice"].Downlink != 34 {
		t.Fatalf("counters changed after failed query: %#v", ledger.Users["alice"])
	}
}

func TestSaturatingAdd(t *testing.T) {
	t.Parallel()
	if got := saturatingAdd(math.MaxInt64-2, 10); got != math.MaxInt64 {
		t.Fatalf("got %d", got)
	}
	if got := saturatingAdd(10, 20); got != 30 {
		t.Fatalf("got %d", got)
	}
}

func writeTestJSON(t *testing.T, path string, value interface{}) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func readTestLedger(t *testing.T, path string) usageLedger {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var ledger usageLedger
	if err := json.Unmarshal(data, &ledger); err != nil {
		t.Fatal(err)
	}
	return ledger
}
