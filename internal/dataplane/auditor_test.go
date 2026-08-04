package dataplane

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDomainAuditorRecordsSniffedDomainAndResets(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	domainPath := filepath.Join(directory, "domains.json")
	writeAuditState(t, statePath, "epoch-1", 20)
	auditor, err := newDomainAuditor(AuditorOptions{
		StatePath: statePath, DomainPath: domainPath,
		SocketPath: filepath.Join(directory, "audit.sock"), FlushInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	current := time.Unix(1_700_000_000, 0)
	auditor.now = func() time.Time { return current }
	auditor.record(routingEvent{
		Email: "alice@hk", Destination: "1.1.1.1:443",
		RouteTarget: "tcp:Example.COM.:443",
	})
	current = current.Add(time.Second)
	auditor.record(routingEvent{Email: "alice@hy2", Destination: "udp:8.8.8.8:53"})
	current = current.Add(time.Second)
	auditor.record(routingEvent{Email: "unknown@hk", Destination: "ignored.example:443"})
	if err := auditor.flush(); err != nil {
		t.Fatal(err)
	}
	ledger := readAuditLedger(t, domainPath)
	user := ledger.Users["alice"]
	if user.Domains["example.com"].Connections != 1 || user.Unresolved != 1 {
		t.Fatalf("unexpected domain ledger: %#v", user)
	}

	writeAuditState(t, statePath, "epoch-2", 20)
	if err := auditor.refreshAndFlush(); err != nil {
		t.Fatal(err)
	}
	reset := readAuditLedger(t, domainPath).Users["alice"]
	if reset.DomainEpoch != "epoch-2" || len(reset.Domains) != 0 || reset.Unresolved != 0 {
		t.Fatalf("domain epoch did not reset ledger: %#v", reset)
	}
}

func TestDomainAuditorCapsOldDomains(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	writeAuditState(t, statePath, "epoch-1", 10)
	auditor, err := newDomainAuditor(AuditorOptions{
		StatePath: statePath, DomainPath: filepath.Join(directory, "domains.json"),
		SocketPath: filepath.Join(directory, "audit.sock"), FlushInterval: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	auditor.maxDomainsPerUser = 2
	current := time.Unix(1_700_000_000, 0)
	auditor.now = func() time.Time { return current }
	for _, domain := range []string{"one.example", "two.example", "three.example"} {
		auditor.record(routingEvent{Email: "alice@hk", Destination: domain + ":443"})
		current = current.Add(time.Second)
	}
	auditor.mu.Lock()
	domains := auditor.ledger.Users["alice"].Domains
	auditor.mu.Unlock()
	if len(domains) != 2 || domains["one.example"].Connections != 0 {
		t.Fatalf("oldest domain was not evicted: %#v", domains)
	}
}

func TestRunAuditorAcceptsUnixWebhook(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	statePath := filepath.Join(directory, "state.json")
	domainPath := filepath.Join(directory, "domains.json")
	socketPath := filepath.Join(directory, "audit.sock")
	writeAuditState(t, statePath, "epoch-1", 20)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- RunAuditor(ctx, AuditorOptions{
			StatePath: statePath, DomainPath: domainPath, SocketPath: socketPath,
			FlushInterval: 20 * time.Millisecond,
		})
	}()
	waitForSocket(t, socketPath)
	transport := &http.Transport{DialContext: func(
		_ context.Context, _, _ string,
	) (net.Conn, error) {
		return net.Dial("unix", socketPath)
	}}
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	response, err := client.Post(
		"http://localhost/event", "application/json",
		strings.NewReader(`{"email":"alice@reality","routeTarget":"tcp:unit.example:443"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("unexpected status %d", response.StatusCode)
	}
	time.Sleep(50 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if readAuditLedger(t, domainPath).Users["alice"].Domains["unit.example"].Connections != 1 {
		t.Fatal("webhook event was not persisted")
	}
}

func writeAuditState(t *testing.T, path, epoch string, maximum int) {
	t.Helper()
	writeTestJSON(t, path, map[string]interface{}{
		"node": map[string]interface{}{"name": "hk"},
		"users": []map[string]interface{}{{
			"name": "alice", "uuid": "uuid-1", "domain_epoch": epoch,
		}},
		"domain_audit": map[string]interface{}{
			"retention_days": 30, "max_domains_per_user": maximum,
		},
	})
}

func readAuditLedger(t *testing.T, path string) domainLedger {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var ledger domainLedger
	if err := json.Unmarshal(data, &ledger); err != nil {
		t.Fatal(err)
	}
	return ledger
}

func waitForSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if info, err := os.Stat(path); err == nil && info.Mode()&os.ModeSocket != 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("domain audit socket was not created")
}
