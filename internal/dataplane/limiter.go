package dataplane

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	socksVersion       = 5
	socksAuthPassword  = 2
	socksAuthVersion   = 1
	socksCommandTCP    = 1
	socksCommandUDP    = 3
	socksAddressIPv4   = 1
	socksAddressDomain = 3
	socksAddressIPv6   = 4
	maxPacketSize      = 64 * 1024
	maxLimiterConfig   = 8 * 1024 * 1024
	maxLimiterClients  = 4096
	maxUDPWorkers      = 256
)

type limiterConfig struct {
	Listen string              `json:"listen"`
	Port   int                 `json:"port"`
	Users  []limiterConfigUser `json:"users"`
}

type limiterConfigUser struct {
	Name     string  `json:"name"`
	Password string  `json:"password"`
	UpMbps   float64 `json:"up_mbps"`
	DownMbps float64 `json:"down_mbps"`
}

type tokenBucket struct {
	mu       sync.Mutex
	rate     float64
	capacity float64
	tokens   float64
	updated  time.Time
}

func newTokenBucket(mbps float64) *tokenBucket {
	rate := mbps * 1_000_000 / 8
	capacity := math.Max(64*1024, rate)
	return &tokenBucket{
		rate:     rate,
		capacity: capacity,
		tokens:   capacity,
		updated:  time.Now(),
	}
}

func (b *tokenBucket) consume(ctx context.Context, amount int) error {
	if b.rate <= 0 || amount <= 0 {
		return nil
	}
	remaining := float64(amount)
	for remaining > 0 {
		chunk := math.Min(remaining, b.capacity)
		for {
			b.mu.Lock()
			now := time.Now()
			elapsed := now.Sub(b.updated).Seconds()
			if elapsed < 0 {
				elapsed = 0
			}
			b.tokens = math.Min(b.capacity, b.tokens+elapsed*b.rate)
			b.updated = now
			delay := time.Duration(0)
			if b.tokens >= chunk {
				b.tokens -= chunk
			} else {
				delay = time.Duration((chunk - b.tokens) / b.rate * float64(time.Second))
			}
			b.mu.Unlock()
			if delay <= 0 {
				break
			}
			timer := time.NewTimer(delay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				if !timer.Stop() {
					<-timer.C
				}
				return ctx.Err()
			}
		}
		remaining -= chunk
	}
	return nil
}

type userLimit struct {
	upload   *tokenBucket
	download *tokenBucket
}

type limiterUser struct {
	password string
	limit    *userLimit
}

type limiterServer struct {
	users map[string]limiterUser
	slots chan struct{}
}

func loadLimiter(path string) (*limiterConfig, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("read limiter config: %w", err)
	}
	defer file.Close()
	var config limiterConfig
	decoder := json.NewDecoder(io.LimitReader(file, maxLimiterConfig+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return nil, fmt.Errorf("decode limiter config: %w", err)
	}
	var trailing interface{}
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("decode limiter config: trailing JSON value")
		}
		return nil, fmt.Errorf("decode limiter config: %w", err)
	}
	if config.Listen != "127.0.0.1" {
		return nil, errors.New("limiter must listen on 127.0.0.1")
	}
	if config.Port < 1 || config.Port > 65535 {
		return nil, errors.New("limiter port must be between 1 and 65535")
	}
	seen := make(map[string]struct{}, len(config.Users))
	for _, user := range config.Users {
		if user.Name == "" || len([]byte(user.Name)) > 255 {
			return nil, errors.New("limiter username must contain 1 to 255 bytes")
		}
		if user.Password == "" || len([]byte(user.Password)) > 255 {
			return nil, fmt.Errorf("limiter password for %q must contain 1 to 255 bytes", user.Name)
		}
		if math.IsNaN(user.UpMbps) || math.IsInf(user.UpMbps, 0) ||
			math.IsNaN(user.DownMbps) || math.IsInf(user.DownMbps, 0) ||
			user.UpMbps < 0 || user.DownMbps < 0 ||
			user.UpMbps > 100000 || user.DownMbps > 100000 {
			return nil, fmt.Errorf("invalid speed limit for %q", user.Name)
		}
		if _, exists := seen[user.Name]; exists {
			return nil, fmt.Errorf("duplicate limiter user %q", user.Name)
		}
		seen[user.Name] = struct{}{}
	}
	return &config, nil
}

func newLimiterServer(config *limiterConfig) *limiterServer {
	server := &limiterServer{
		users: make(map[string]limiterUser, len(config.Users)),
		slots: make(chan struct{}, maxLimiterClients),
	}
	for _, item := range config.Users {
		server.users[item.Name] = limiterUser{
			password: item.Password,
			limit: &userLimit{
				upload:   newTokenBucket(item.UpMbps),
				download: newTokenBucket(item.DownMbps),
			},
		}
	}
	return server
}

// RunLimiter serves a localhost-only authenticated SOCKS5 proxy.
func RunLimiter(ctx context.Context, configPath string) error {
	config, err := loadLimiter(configPath)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort(config.Listen, strconv.Itoa(config.Port)))
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()

	server := newLimiterServer(config)
	go func() {
		<-ctx.Done()
		listener.Close()
	}()
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if ctx.Err() != nil {
				return nil
			}
			if temporary, ok := acceptErr.(interface{ Temporary() bool }); ok && temporary.Temporary() {
				time.Sleep(50 * time.Millisecond)
				continue
			}
			return fmt.Errorf("accept: %w", acceptErr)
		}
		select {
		case server.slots <- struct{}{}:
			go func() {
				defer func() { <-server.slots }()
				server.handleConnection(ctx, connection)
			}()
		default:
			connection.Close()
		}
	}
}

func (s *limiterServer) handleConnection(parent context.Context, connection net.Conn) {
	defer connection.Close()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	connection.SetDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(connection)
	limit, err := s.authenticate(reader, connection)
	if err != nil || limit == nil {
		return
	}
	connection.SetDeadline(time.Time{})

	header := make([]byte, 4)
	if _, err := io.ReadFull(reader, header); err != nil {
		return
	}
	if header[0] != socksVersion || header[2] != 0 {
		return
	}
	host, port, err := readSOCKSAddress(reader, header[3])
	if err != nil {
		writeSOCKSFailure(connection, 8)
		return
	}
	switch header[1] {
	case socksCommandTCP:
		s.handleTCP(ctx, reader, connection, host, port, limit)
	case socksCommandUDP:
		s.handleUDP(ctx, reader, connection, limit)
	default:
		writeSOCKSFailure(connection, 7)
	}
}

func (s *limiterServer) authenticate(reader *bufio.Reader, writer io.Writer) (*userLimit, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	if header[0] != socksVersion || header[1] == 0 {
		return nil, errors.New("invalid SOCKS greeting")
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(reader, methods); err != nil {
		return nil, err
	}
	found := false
	for _, method := range methods {
		if method == socksAuthPassword {
			found = true
			break
		}
	}
	if !found {
		_, _ = writer.Write([]byte{socksVersion, 0xff})
		return nil, errors.New("username/password authentication required")
	}
	if _, err := writer.Write([]byte{socksVersion, socksAuthPassword}); err != nil {
		return nil, err
	}

	authHeader := make([]byte, 2)
	if _, err := io.ReadFull(reader, authHeader); err != nil {
		return nil, err
	}
	if authHeader[0] != socksAuthVersion || authHeader[1] == 0 {
		return nil, errors.New("invalid SOCKS authentication request")
	}
	usernameBytes := make([]byte, int(authHeader[1]))
	if _, err := io.ReadFull(reader, usernameBytes); err != nil {
		return nil, err
	}
	passwordLength, err := reader.ReadByte()
	if err != nil || passwordLength == 0 {
		return nil, errors.New("invalid SOCKS password")
	}
	passwordBytes := make([]byte, int(passwordLength))
	if _, err := io.ReadFull(reader, passwordBytes); err != nil {
		return nil, err
	}

	record, exists := s.users[string(usernameBytes)]
	expected := record.password
	if !exists {
		expected = strings.Repeat("\x00", len(passwordBytes))
	}
	valid := exists && subtle.ConstantTimeCompare(passwordBytes, []byte(expected)) == 1
	status := byte(1)
	if valid {
		status = 0
	}
	if _, err := writer.Write([]byte{socksAuthVersion, status}); err != nil {
		return nil, err
	}
	if !valid {
		return nil, errors.New("SOCKS authentication failed")
	}
	return record.limit, nil
}

func (s *limiterServer) handleTCP(
	ctx context.Context,
	clientReader io.Reader,
	client net.Conn,
	host string,
	port int,
	limit *userLimit,
) {
	dialer := net.Dialer{Timeout: 20 * time.Second}
	remote, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		writeSOCKSFailure(client, 5)
		return
	}
	defer remote.Close()
	reply, err := packSOCKSReply(0, remote.LocalAddr())
	if err != nil {
		writeSOCKSFailure(client, 1)
		return
	}
	if _, err := client.Write(reply); err != nil {
		return
	}

	closed := make(chan struct{})
	defer close(closed)
	go func() {
		select {
		case <-ctx.Done():
			client.Close()
			remote.Close()
		case <-closed:
		}
	}()
	results := make(chan struct{}, 2)
	go func() {
		copyLimited(ctx, remote, clientReader, limit.upload)
		results <- struct{}{}
	}()
	go func() {
		copyLimited(ctx, client, remote, limit.download)
		results <- struct{}{}
	}()
	<-results
	client.Close()
	remote.Close()
	<-results
}

func copyLimited(ctx context.Context, destination io.Writer, source io.Reader, bucket *tokenBucket) {
	buffer := make([]byte, maxPacketSize)
	for {
		count, readErr := source.Read(buffer)
		if count > 0 {
			if err := bucket.consume(ctx, count); err != nil {
				return
			}
			if _, err := writeFull(destination, buffer[:count]); err != nil {
				return
			}
		}
		if readErr != nil {
			return
		}
	}
}

func writeFull(writer io.Writer, data []byte) (int, error) {
	total := 0
	for len(data) > 0 {
		count, err := writer.Write(data)
		total += count
		data = data[count:]
		if err != nil {
			return total, err
		}
		if count == 0 {
			return total, io.ErrShortWrite
		}
	}
	return total, nil
}

func (s *limiterServer) handleUDP(
	ctx context.Context,
	controlReader io.Reader,
	control net.Conn,
	limit *userLimit,
) {
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		writeSOCKSFailure(control, 1)
		return
	}
	defer relay.Close()
	reply, err := packSOCKSReply(0, relay.LocalAddr())
	if err != nil {
		writeSOCKSFailure(control, 1)
		return
	}
	if _, err := control.Write(reply); err != nil {
		return
	}

	controlPeer, ok := control.RemoteAddr().(*net.TCPAddr)
	if !ok {
		return
	}
	relayCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-relayCtx.Done()
		relay.Close()
	}()
	go func() {
		buffer := make([]byte, 1)
		_, _ = controlReader.Read(buffer)
		cancel()
	}()

	var client *net.UDPAddr
	var targets sync.Map
	workers := make(chan struct{}, maxUDPWorkers)
	buffer := make([]byte, 65535)
	for {
		count, source, readErr := relay.ReadFromUDP(buffer)
		if readErr != nil {
			if relayCtx.Err() != nil {
				return
			}
			continue
		}
		packet := append([]byte(nil), buffer[:count]...)
		if client == nil {
			if !source.IP.Equal(controlPeer.IP) {
				continue
			}
			if _, _, _, parseErr := unpackUDPRequest(packet); parseErr != nil {
				continue
			}
			client = source
		}
		if source.IP.Equal(client.IP) && source.Port == client.Port {
			select {
			case workers <- struct{}{}:
				go func() {
					defer func() { <-workers }()
					host, port, payload, parseErr := unpackUDPRequest(packet)
					if parseErr != nil {
						return
					}
					target, resolveErr := net.ResolveUDPAddr(
						"udp4",
						net.JoinHostPort(host, strconv.Itoa(port)),
					)
					if resolveErr != nil {
						return
					}
					if err := limit.upload.consume(relayCtx, len(payload)); err != nil {
						return
					}
					targets.Store(target.String(), struct{}{})
					_, _ = relay.WriteToUDP(payload, target)
				}()
			default:
			}
			continue
		}
		if _, allowed := targets.Load(source.String()); !allowed {
			continue
		}
		select {
		case workers <- struct{}{}:
			go func() {
				defer func() { <-workers }()
				if err := limit.download.consume(relayCtx, len(packet)); err != nil {
					return
				}
				wrapped, packErr := packUDPResponse(source, packet)
				if packErr == nil {
					_, _ = relay.WriteToUDP(wrapped, client)
				}
			}()
		default:
		}
	}
}

func readSOCKSAddress(reader io.Reader, addressType byte) (string, int, error) {
	var host string
	switch addressType {
	case socksAddressIPv4:
		value := make([]byte, net.IPv4len)
		if _, err := io.ReadFull(reader, value); err != nil {
			return "", 0, err
		}
		host = net.IP(value).String()
	case socksAddressDomain:
		length := make([]byte, 1)
		if _, err := io.ReadFull(reader, length); err != nil {
			return "", 0, err
		}
		if length[0] == 0 {
			return "", 0, errors.New("empty SOCKS domain")
		}
		value := make([]byte, int(length[0]))
		if _, err := io.ReadFull(reader, value); err != nil {
			return "", 0, err
		}
		host = string(value)
	case socksAddressIPv6:
		value := make([]byte, net.IPv6len)
		if _, err := io.ReadFull(reader, value); err != nil {
			return "", 0, err
		}
		host = net.IP(value).String()
	default:
		return "", 0, errors.New("unsupported SOCKS address type")
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(reader, portBytes); err != nil {
		return "", 0, err
	}
	return host, int(binary.BigEndian.Uint16(portBytes)), nil
}

func packAddress(host string, port int) ([]byte, error) {
	if port < 0 || port > 65535 {
		return nil, errors.New("invalid port")
	}
	ip := net.ParseIP(host)
	var result []byte
	if ipv4 := ip.To4(); ipv4 != nil {
		result = append([]byte{socksAddressIPv4}, ipv4...)
	} else if ipv6 := ip.To16(); ipv6 != nil {
		result = append([]byte{socksAddressIPv6}, ipv6...)
	} else {
		hostBytes := []byte(host)
		if len(hostBytes) == 0 || len(hostBytes) > 255 {
			return nil, errors.New("invalid SOCKS domain")
		}
		result = append([]byte{socksAddressDomain, byte(len(hostBytes))}, hostBytes...)
	}
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(port))
	return append(result, portBytes...), nil
}

func packSOCKSReply(status byte, address net.Addr) ([]byte, error) {
	host, portValue, err := net.SplitHostPort(address.String())
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portValue)
	if err != nil {
		return nil, err
	}
	packed, err := packAddress(host, port)
	if err != nil {
		return nil, err
	}
	return append([]byte{socksVersion, status, 0}, packed...), nil
}

func writeSOCKSFailure(writer io.Writer, status byte) {
	_, _ = writer.Write([]byte{socksVersion, status, 0, socksAddressIPv4, 0, 0, 0, 0, 0, 0})
}

func unpackUDPRequest(packet []byte) (string, int, []byte, error) {
	if len(packet) < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
		return "", 0, nil, errors.New("invalid SOCKS UDP packet")
	}
	reader := bytesReader(packet[4:])
	host, port, err := readSOCKSAddress(&reader, packet[3])
	if err != nil {
		return "", 0, nil, err
	}
	offset := len(packet) - reader.Len()
	if offset > len(packet) {
		return "", 0, nil, errors.New("invalid SOCKS UDP offset")
	}
	return host, port, packet[offset:], nil
}

type byteSliceReader struct {
	data   []byte
	offset int
}

func bytesReader(data []byte) byteSliceReader {
	return byteSliceReader{data: data}
}

func (r *byteSliceReader) Read(target []byte) (int, error) {
	if r.offset >= len(r.data) {
		return 0, io.EOF
	}
	count := copy(target, r.data[r.offset:])
	r.offset += count
	return count, nil
}

func (r *byteSliceReader) Len() int {
	return len(r.data) - r.offset
}

func packUDPResponse(source *net.UDPAddr, payload []byte) ([]byte, error) {
	address, err := packAddress(source.IP.String(), source.Port)
	if err != nil {
		return nil, err
	}
	result := make([]byte, 0, 3+len(address)+len(payload))
	result = append(result, 0, 0, 0)
	result = append(result, address...)
	result = append(result, payload...)
	return result, nil
}
