package dataplane

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadLimiterRejectsUnsafeConfiguration(t *testing.T) {
	t.Parallel()
	tests := []string{
		`{"listen":"0.0.0.0","port":18181,"users":[]}`,
		`{"listen":"127.0.0.1","port":0,"users":[]}`,
		`{"listen":"127.0.0.1","port":18181,"users":[{"name":"a","password":"x","up_mbps":-1,"down_mbps":0}]}`,
		`{"listen":"127.0.0.1","port":18181,"users":[{"name":"a","password":"x","up_mbps":0,"down_mbps":0},{"name":"a","password":"y","up_mbps":0,"down_mbps":0}]}`,
		`{"listen":"127.0.0.1","port":18181,"users":[],"extra":true}`,
	}
	for _, value := range tests {
		path := filepath.Join(t.TempDir(), "limits.json")
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadLimiter(path); err == nil {
			t.Fatalf("loadLimiter accepted %s", value)
		}
	}
}

func TestTokenBucketIsShared(t *testing.T) {
	bucket := newTokenBucket(1)
	bucket.mu.Lock()
	bucket.capacity = 1000
	bucket.tokens = 0
	bucket.updated = time.Now()
	bucket.mu.Unlock()

	start := time.Now()
	var completed = make(chan struct{}, 2)
	for range 2 {
		go func() {
			if err := bucket.consume(context.Background(), 1000); err != nil {
				t.Error(err)
			}
			completed <- struct{}{}
		}()
	}
	<-completed
	<-completed
	if elapsed := time.Since(start); elapsed < 14*time.Millisecond {
		t.Fatalf("aggregate limiter completed too quickly: %v", elapsed)
	}
}

func TestPackAndReadAddresses(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		host string
		port int
	}{
		{"127.0.0.1", 443},
		{"::1", 8443},
		{"example.com", 53},
	} {
		packed, err := packAddress(test.host, test.port)
		if err != nil {
			t.Fatal(err)
		}
		host, port, err := readSOCKSAddress(bytes.NewReader(packed[1:]), packed[0])
		if err != nil {
			t.Fatal(err)
		}
		if host != test.host || port != test.port {
			t.Fatalf("got %s:%d, want %s:%d", host, port, test.host, test.port)
		}
	}
}

func TestLimiterTCPAuthenticationAndRelay(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			connection, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			go io.Copy(connection, connection)
		}
	}()

	config := &limiterConfig{
		Listen: "127.0.0.1",
		Users: []limiterConfigUser{{
			Name: "alice", Password: "secret",
		}},
	}
	server := newLimiterServer(config)
	serverListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer serverListener.Close()
	go func() {
		connection, acceptErr := serverListener.Accept()
		if acceptErr == nil {
			server.handleConnection(context.Background(), connection)
		}
	}()

	client, err := net.Dial("tcp4", serverListener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := client.Write([]byte{5, 1, 2}); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(client, reply); err != nil || !bytes.Equal(reply, []byte{5, 2}) {
		t.Fatalf("method reply %v: %v", reply, err)
	}
	if _, err := client.Write(append([]byte{1, 5}, append([]byte("alice"), append([]byte{6}, []byte("secret")...)...)...)); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(client, reply); err != nil || !bytes.Equal(reply, []byte{1, 0}) {
		t.Fatalf("auth reply %v: %v", reply, err)
	}
	target := listener.Addr().(*net.TCPAddr)
	request := []byte{5, 1, 0, 1, 127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(request[8:], uint16(target.Port))
	if _, err := client.Write(request); err != nil {
		t.Fatal(err)
	}
	responseHeader := make([]byte, 4)
	if _, err := io.ReadFull(client, responseHeader); err != nil {
		t.Fatal(err)
	}
	if responseHeader[1] != 0 {
		t.Fatalf("connect failed with status %d", responseHeader[1])
	}
	switch responseHeader[3] {
	case 1:
		_, err = io.CopyN(io.Discard, client, 6)
	case 4:
		_, err = io.CopyN(io.Discard, client, 18)
	default:
		t.Fatalf("unexpected response address type %d", responseHeader[3])
	}
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("through-limiter")
	if _, err := client.Write(payload); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(client, response); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(response, payload) {
		t.Fatalf("got %q", response)
	}
}

func TestInvalidSpeedIsFinite(t *testing.T) {
	t.Parallel()
	for _, value := range []float64{math.Inf(1), math.NaN(), -1, 100001} {
		if !(math.IsInf(value, 0) || math.IsNaN(value) || value < 0 || value > 100000) {
			t.Fatalf("test assumption failed for %v", value)
		}
	}
}
