package dataplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	defaultDomainRetentionDays = 30
	defaultMaxDomainsPerUser   = 500
	maxAuditRequestBytes       = 16 * 1024
	maxDomainLedgerBytes       = 32 * 1024 * 1024
)

type AuditorOptions struct {
	StatePath     string
	DomainPath    string
	SocketPath    string
	FlushInterval time.Duration
}

type auditStateFile struct {
	Node struct {
		Name string `json:"name"`
	} `json:"node"`
	Users       []auditStateUser `json:"users"`
	DomainAudit struct {
		RetentionDays     int `json:"retention_days"`
		MaxDomainsPerUser int `json:"max_domains_per_user"`
	} `json:"domain_audit"`
}

type auditStateUser struct {
	Name        string `json:"name"`
	UUID        string `json:"uuid"`
	DomainEpoch string `json:"domain_epoch"`
}

type domainLedger struct {
	Schema    int                         `json:"schema"`
	UpdatedAt int64                       `json:"updated_at"`
	Node      string                      `json:"node"`
	Users     map[string]domainLedgerUser `json:"users"`
}

type domainLedgerUser struct {
	UUID        string                  `json:"uuid"`
	DomainEpoch string                  `json:"domain_epoch"`
	Unresolved  int64                   `json:"unresolved"`
	Domains     map[string]domainRecord `json:"domains"`
}

type domainRecord struct {
	Connections int64 `json:"connections"`
	FirstSeen   int64 `json:"first_seen"`
	LastSeen    int64 `json:"last_seen"`
}

type routingEvent struct {
	Email          string `json:"email"`
	Destination    string `json:"destination"`
	OriginalTarget string `json:"originalTarget"`
	RouteTarget    string `json:"routeTarget"`
}

type domainAuditor struct {
	mu                sync.Mutex
	options           AuditorOptions
	node              string
	users             map[string]auditStateUser
	retentionDays     int
	maxDomainsPerUser int
	ledger            domainLedger
	dirty             bool
	now               func() time.Time
}

func RunAuditor(ctx context.Context, options AuditorOptions) error {
	if options.StatePath == "" || options.DomainPath == "" || options.SocketPath == "" {
		return errors.New("auditor paths must not be empty")
	}
	if options.FlushInterval <= 0 {
		return errors.New("auditor flush interval must be positive")
	}
	auditor, err := newDomainAuditor(options)
	if err != nil {
		return err
	}
	if err := prepareUnixSocket(options.SocketPath); err != nil {
		return err
	}
	listener, err := net.Listen("unix", options.SocketPath)
	if err != nil {
		return fmt.Errorf("listen on domain audit socket: %w", err)
	}
	defer func() {
		listener.Close()
		os.Remove(options.SocketPath)
	}()
	if err := os.Chmod(options.SocketPath, 0600); err != nil {
		return fmt.Errorf("secure domain audit socket: %w", err)
	}

	server := &http.Server{
		Handler:           auditor,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       15 * time.Second,
		MaxHeaderBytes:    8 * 1024,
	}
	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- server.Serve(listener)
	}()
	ticker := time.NewTicker(options.FlushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = server.Shutdown(shutdownCtx)
			cancel()
			return auditor.flush()
		case err := <-serverErrors:
			if errors.Is(err, http.ErrServerClosed) {
				return auditor.flush()
			}
			return fmt.Errorf("serve domain audit socket: %w", err)
		case <-ticker.C:
			if err := auditor.refreshAndFlush(); err != nil {
				fmt.Fprintf(os.Stderr, "etxr-domain-audit: %v\n", err)
			}
		}
	}
}

func newDomainAuditor(options AuditorOptions) (*domainAuditor, error) {
	auditor := &domainAuditor{options: options, now: time.Now}
	if err := auditor.refreshState(); err != nil {
		return nil, err
	}
	ledger, err := readDomainLedger(options.DomainPath)
	if err != nil {
		return nil, err
	}
	auditor.ledger = ledger
	auditor.mu.Lock()
	auditor.reconcileLocked()
	auditor.mu.Unlock()
	return auditor, nil
}

func (auditor *domainAuditor) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost || request.URL.Path != "/event" {
		http.NotFound(writer, request)
		return
	}
	decoder := json.NewDecoder(io.LimitReader(request.Body, maxAuditRequestBytes+1))
	var event routingEvent
	if err := decoder.Decode(&event); err != nil {
		http.Error(writer, "invalid event", http.StatusBadRequest)
		return
	}
	var trailing interface{}
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		http.Error(writer, "invalid event", http.StatusBadRequest)
		return
	}
	auditor.record(event)
	writer.WriteHeader(http.StatusNoContent)
}

func (auditor *domainAuditor) record(event routingEvent) {
	username := event.Email
	if index := strings.LastIndex(username, "@"); index >= 0 {
		username = username[:index]
	}
	if username == "" {
		return
	}
	domain := firstDomain(event.RouteTarget, event.Destination, event.OriginalTarget)
	now := auditor.now().Unix()

	auditor.mu.Lock()
	defer auditor.mu.Unlock()
	identity, exists := auditor.users[username]
	if !exists {
		return
	}
	current, exists := auditor.ledger.Users[username]
	if !exists || current.UUID != identity.UUID || current.DomainEpoch != identity.DomainEpoch {
		current = newDomainLedgerUser(identity)
	}
	if domain == "" {
		current.Unresolved = saturatingAdd(current.Unresolved, 1)
	} else {
		entry, found := current.Domains[domain]
		if !found {
			entry.FirstSeen = now
		}
		entry.Connections = saturatingAdd(entry.Connections, 1)
		entry.LastSeen = now
		current.Domains[domain] = entry
		pruneDomainMap(current.Domains, auditor.maxDomainsPerUser, 0)
	}
	auditor.ledger.Users[username] = current
	auditor.dirty = true
}

func (auditor *domainAuditor) refreshAndFlush() error {
	if err := auditor.refreshState(); err != nil {
		return err
	}
	return auditor.flush()
}

func (auditor *domainAuditor) refreshState() error {
	var state auditStateFile
	if err := readJSONLimited(auditor.options.StatePath, maxStateBytes, &state); err != nil {
		return fmt.Errorf("decode domain audit state: %w", err)
	}
	users := make(map[string]auditStateUser, len(state.Users))
	for _, user := range state.Users {
		if user.Name == "" || user.UUID == "" {
			return errors.New("state contains an invalid domain audit user")
		}
		if _, exists := users[user.Name]; exists {
			return fmt.Errorf("state contains duplicate user %q", user.Name)
		}
		users[user.Name] = user
	}
	retentionDays := state.DomainAudit.RetentionDays
	if retentionDays == 0 {
		retentionDays = defaultDomainRetentionDays
	}
	maxDomains := state.DomainAudit.MaxDomainsPerUser
	if maxDomains == 0 {
		maxDomains = defaultMaxDomainsPerUser
	}
	if retentionDays < 1 || retentionDays > 365 || maxDomains < 10 || maxDomains > 5000 {
		return errors.New("state contains invalid domain audit limits")
	}

	auditor.mu.Lock()
	auditor.node = state.Node.Name
	auditor.users = users
	auditor.retentionDays = retentionDays
	auditor.maxDomainsPerUser = maxDomains
	auditor.reconcileLocked()
	auditor.mu.Unlock()
	return nil
}

func (auditor *domainAuditor) reconcileLocked() {
	if auditor.ledger.Schema == 0 {
		auditor.ledger.Schema = 1
	}
	if auditor.ledger.Users == nil {
		auditor.ledger.Users = make(map[string]domainLedgerUser)
	}
	if auditor.ledger.Node != auditor.node {
		auditor.ledger.Node = auditor.node
		auditor.dirty = true
	}
	cutoff := auditor.now().Add(-time.Duration(auditor.retentionDays) * 24 * time.Hour).Unix()
	for name, identity := range auditor.users {
		current, exists := auditor.ledger.Users[name]
		if !exists || current.UUID != identity.UUID || current.DomainEpoch != identity.DomainEpoch {
			auditor.ledger.Users[name] = newDomainLedgerUser(identity)
			auditor.dirty = true
			continue
		}
		if current.Domains == nil {
			current.Domains = make(map[string]domainRecord)
		}
		before := len(current.Domains)
		pruneDomainMap(current.Domains, auditor.maxDomainsPerUser, cutoff)
		if len(current.Domains) != before {
			auditor.dirty = true
		}
		auditor.ledger.Users[name] = current
	}
	for name := range auditor.ledger.Users {
		if _, exists := auditor.users[name]; !exists {
			delete(auditor.ledger.Users, name)
			auditor.dirty = true
		}
	}
}

func (auditor *domainAuditor) flush() error {
	auditor.mu.Lock()
	defer auditor.mu.Unlock()
	if !auditor.dirty {
		return nil
	}
	auditor.ledger.Schema = 1
	auditor.ledger.UpdatedAt = auditor.now().Unix()
	if err := atomicJSON(auditor.options.DomainPath, auditor.ledger); err != nil {
		return fmt.Errorf("write domain audit ledger: %w", err)
	}
	auditor.dirty = false
	return nil
}

func newDomainLedgerUser(identity auditStateUser) domainLedgerUser {
	return domainLedgerUser{
		UUID: identity.UUID, DomainEpoch: identity.DomainEpoch,
		Domains: make(map[string]domainRecord),
	}
}

func readDomainLedger(path string) (domainLedger, error) {
	ledger := domainLedger{Schema: 1, Users: make(map[string]domainLedgerUser)}
	if err := readJSONLimited(path, maxDomainLedgerBytes, &ledger); errors.Is(err, os.ErrNotExist) {
		return ledger, nil
	} else if err != nil {
		return ledger, fmt.Errorf("decode domain audit ledger: %w", err)
	}
	if ledger.Schema != 1 {
		return ledger, fmt.Errorf("unsupported domain audit schema %d", ledger.Schema)
	}
	if ledger.Users == nil {
		ledger.Users = make(map[string]domainLedgerUser)
	}
	return ledger, nil
}

func prepareUnixSocket(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("domain audit socket path must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create domain audit socket directory: %w", err)
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("refusing to replace non-socket domain audit path")
	}
	return os.Remove(path)
}

func firstDomain(values ...string) string {
	for _, value := range values {
		if domain := domainFromTarget(value); domain != "" {
			return domain
		}
	}
	return ""
}

func domainFromTarget(value string) string {
	value = strings.TrimSpace(value)
	for _, prefix := range []string{"tcp:", "udp:"} {
		if strings.HasPrefix(strings.ToLower(value), prefix) {
			value = value[len(prefix):]
			break
		}
	}
	host := value
	if parsed, _, err := net.SplitHostPort(value); err == nil {
		host = parsed
	}
	host = strings.ToLower(strings.TrimSuffix(strings.Trim(host, "[]"), "."))
	if host == "" || len(host) > 253 || net.ParseIP(host) != nil {
		return ""
	}
	for _, character := range host {
		if (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') ||
			character == '.' || character == '-' || character == '_' {
			continue
		}
		return ""
	}
	return host
}

func pruneDomainMap(domains map[string]domainRecord, maximum int, cutoff int64) {
	for domain, record := range domains {
		if record.Connections <= 0 || record.LastSeen <= 0 ||
			(cutoff > 0 && record.LastSeen < cutoff) {
			delete(domains, domain)
		}
	}
	if len(domains) <= maximum {
		return
	}
	type candidate struct {
		domain string
		record domainRecord
	}
	items := make([]candidate, 0, len(domains))
	for domain, record := range domains {
		items = append(items, candidate{domain: domain, record: record})
	}
	sort.Slice(items, func(left, right int) bool {
		if items[left].record.LastSeen != items[right].record.LastSeen {
			return items[left].record.LastSeen > items[right].record.LastSeen
		}
		if items[left].record.Connections != items[right].record.Connections {
			return items[left].record.Connections > items[right].record.Connections
		}
		return items[left].domain < items[right].domain
	})
	for _, item := range items[maximum:] {
		delete(domains, item.domain)
	}
}
