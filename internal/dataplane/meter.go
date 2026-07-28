package dataplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var statPattern = regexp.MustCompile(`^user>>>(.+)>>>traffic>>>(uplink|downlink)$`)

const (
	maxStateBytes = 8 * 1024 * 1024
	maxStatsBytes = 32 * 1024 * 1024
)

type MeterOptions struct {
	StatePath string
	UsagePath string
	XrayBin   string
	Interval  time.Duration
	Once      bool
}

type stateFile struct {
	Users     []stateUser    `json:"users"`
	DataPlane stateDataPlane `json:"data_plane"`
}

type stateUser struct {
	Name       string `json:"name"`
	UUID       string `json:"uuid"`
	UsageEpoch string `json:"usage_epoch"`
}

type stateDataPlane struct {
	XrayAPIPort int `json:"xray_api_port"`
}

type usageLedger struct {
	Schema    int                         `json:"schema"`
	UpdatedAt int64                       `json:"updated_at"`
	Raw       map[string]map[string]int64 `json:"raw"`
	Users     map[string]usageLedgerUser  `json:"users"`
}

type usageLedgerUser struct {
	UUID       string `json:"uuid"`
	UsageEpoch string `json:"usage_epoch"`
	Uplink     int64  `json:"uplink"`
	Downlink   int64  `json:"downlink"`
}

type xrayStatsPayload struct {
	Stats []xrayStat `json:"stat"`
}

type xrayStat struct {
	Name  string      `json:"name"`
	Value interface{} `json:"value"`
}

type statsQuery func(context.Context, string, int) (map[string]int64, bool)

type cappedBuffer struct {
	buffer bytes.Buffer
	limit  int
}

func (writer *cappedBuffer) Write(value []byte) (int, error) {
	remaining := writer.limit - writer.buffer.Len()
	if remaining <= 0 {
		return 0, errors.New("Xray stats output is too large")
	}
	if len(value) > remaining {
		_, _ = writer.buffer.Write(value[:remaining])
		return remaining, errors.New("Xray stats output is too large")
	}
	return writer.buffer.Write(value)
}

// RunMeter periodically folds reset-on-read Xray counters into a durable ledger.
func RunMeter(ctx context.Context, options MeterOptions) error {
	if options.StatePath == "" || options.UsagePath == "" || options.XrayBin == "" {
		return errors.New("meter paths must not be empty")
	}
	if options.Interval <= 0 {
		return errors.New("meter interval must be positive")
	}
	for {
		if err := scrapeUsage(ctx, options, queryStats); err != nil {
			fmt.Fprintf(os.Stderr, "etxr-meter: %v\n", err)
		}
		if options.Once {
			return nil
		}
		timer := time.NewTimer(options.Interval)
		select {
		case <-timer.C:
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return nil
		}
	}
}

func queryStats(parent context.Context, xrayBin string, port int) (map[string]int64, bool) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	command := exec.CommandContext(
		ctx,
		xrayBin,
		"api",
		"statsquery",
		fmt.Sprintf("--server=127.0.0.1:%d", port),
		"-pattern",
		"user>>>",
		"-reset=true",
	)
	output := &cappedBuffer{limit: maxStatsBytes}
	command.Stdout = output
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return nil, false
	}
	var payload xrayStatsPayload
	if err := json.Unmarshal(output.buffer.Bytes(), &payload); err != nil {
		return nil, false
	}
	values := make(map[string]int64, len(payload.Stats))
	for _, item := range payload.Stats {
		if item.Name == "" {
			continue
		}
		value, ok := parseCounter(item.Value)
		if ok {
			values[item.Name] = value
		}
	}
	return values, true
}

func parseCounter(value interface{}) (int64, bool) {
	switch typed := value.(type) {
	case string:
		parsed, err := strconv.ParseInt(typed, 10, 64)
		return parsed, err == nil
	case float64:
		if typed < float64(-1<<63) || typed > float64(1<<63-1) || typed != float64(int64(typed)) {
			return 0, false
		}
		return int64(typed), true
	case json.Number:
		parsed, err := typed.Int64()
		return parsed, err == nil
	default:
		return 0, false
	}
}

func scrapeUsage(ctx context.Context, options MeterOptions, query statsQuery) error {
	var state stateFile
	if err := readJSONLimited(options.StatePath, maxStateBytes, &state); err != nil {
		return fmt.Errorf("decode state: %w", err)
	}
	users := make(map[string]stateUser, len(state.Users))
	for _, user := range state.Users {
		if user.Name == "" || user.UUID == "" {
			return errors.New("state contains an invalid usage user")
		}
		if _, exists := users[user.Name]; exists {
			return fmt.Errorf("state contains duplicate user %q", user.Name)
		}
		users[user.Name] = user
	}

	lock, err := acquireFileLock(options.UsagePath + ".lock")
	if err != nil {
		return fmt.Errorf("lock usage ledger: %w", err)
	}
	defer lock.Close()

	ledger, err := readLedger(options.UsagePath)
	if err != nil {
		return err
	}
	for name, identity := range users {
		current, exists := ledger.Users[name]
		if !exists || current.UUID != identity.UUID || current.UsageEpoch != identity.UsageEpoch {
			ledger.Users[name] = usageLedgerUser{
				UUID:       identity.UUID,
				UsageEpoch: identity.UsageEpoch,
			}
		} else if current.Uplink < 0 || current.Downlink < 0 {
			current.Uplink = max(0, current.Uplink)
			current.Downlink = max(0, current.Downlink)
			ledger.Users[name] = current
		}
	}
	for name := range ledger.Users {
		if _, exists := users[name]; !exists {
			delete(ledger.Users, name)
		}
	}

	port := state.DataPlane.XrayAPIPort
	if port == 0 {
		port = 18182
	}
	if stats, ok := query(ctx, options.XrayBin, port); ok {
		for statName, value := range stats {
			match := statPattern.FindStringSubmatch(statName)
			if match == nil {
				continue
			}
			authName := match[1]
			username := authName
			if index := strings.LastIndex(authName, "@"); index >= 0 {
				username = authName[:index]
			}
			current, exists := ledger.Users[username]
			if !exists {
				continue
			}
			if value < 0 {
				value = 0
			}
			if match[2] == "uplink" {
				current.Uplink = saturatingAdd(current.Uplink, value)
			} else {
				current.Downlink = saturatingAdd(current.Downlink, value)
			}
			ledger.Users[username] = current
		}
		ledger.Raw["xray"] = stats
	}
	ledger.UpdatedAt = time.Now().Unix()
	if err := atomicJSON(options.UsagePath, ledger); err != nil {
		return fmt.Errorf("write usage ledger: %w", err)
	}
	return nil
}

func readLedger(path string) (usageLedger, error) {
	ledger := usageLedger{
		Schema: 1,
		Raw:    make(map[string]map[string]int64),
		Users:  make(map[string]usageLedgerUser),
	}
	if err := readJSONLimited(path, maxStateBytes, &ledger); errors.Is(err, os.ErrNotExist) {
		return ledger, nil
	} else if err != nil {
		return ledger, fmt.Errorf("decode usage ledger: %w", err)
	}
	if ledger.Schema == 0 {
		ledger.Schema = 1
	}
	if ledger.Raw == nil {
		ledger.Raw = make(map[string]map[string]int64)
	}
	if ledger.Users == nil {
		ledger.Users = make(map[string]usageLedgerUser)
	}
	return ledger, nil
}

func readJSONLimited(path string, limit int64, destination interface{}) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, limit+1))
	decoder.UseNumber()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing interface{}
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("trailing JSON value")
		}
		return err
	}
	return nil
}

func saturatingAdd(left, right int64) int64 {
	if right > 0 && left > int64(^uint64(0)>>1)-right {
		return int64(^uint64(0) >> 1)
	}
	return left + right
}

func atomicJSON(path string, value interface{}) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, filepath.Base(path)+".")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := replaceFile(temporaryName, path); err != nil {
		return err
	}
	return syncDirectory(directory)
}
