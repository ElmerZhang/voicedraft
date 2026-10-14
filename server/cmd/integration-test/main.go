// integration-test runs the Swift suite against isolated synthetic Go services.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"voicedraft/server/internal/syncserver"
	"voicedraft/server/internal/testfixture"
)

func main() {
	root := flag.String("root", "..", "VoiceDraft repository directory")
	flag.Parse()
	if err := run(*root); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(root string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	directory, err := os.MkdirTemp("", "voicedraft-test-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	store, err := syncserver.OpenStore(filepath.Join(directory, "vault.sqlite3"))
	if err != nil {
		return err
	}
	defer store.Close()
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	token := base64.RawURLEncoding.EncodeToString(random[:])
	syncHandler, err := syncserver.NewHandler(store, token)
	if err != nil {
		return err
	}
	fixture := &testfixture.Handler{Sync: syncHandler}
	server := syncserver.NewHTTPServer("127.0.0.1:0", fixture)
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return fmt.Errorf("cannot start isolated loopback fixture: %w", err)
	}
	finished := make(chan error, 1)
	go func() { finished <- server.Serve(listener) }()
	defer func() { _ = server.Close(); <-finished }()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	command := exec.CommandContext(ctx, "swift", "test", "--disable-sandbox")
	command.Dir = root
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	overrides := map[string]string{
		"VOICEDRAFT_TEST_SERVER": "http://" + listener.Addr().String(), "VOICEDRAFT_TEST_TOKEN": token,
		"CLANG_MODULE_CACHE_PATH":      filepath.Join(root, ".build/clang-cache"),
		"SWIFTPM_MODULECACHE_OVERRIDE": filepath.Join(root, ".build/swift-cache"),
	}
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if _, replaced := overrides[key]; !replaced {
			command.Env = append(command.Env, entry)
		}
	}
	for key, value := range overrides {
		command.Env = append(command.Env, key+"="+value)
	}
	if err := command.Run(); err != nil {
		return err
	}
	if fixture.Leaked.Load() {
		return errors.New("client followed a credential-bearing redirect")
	}
	select {
	case err := <-finished:
		finished <- err
		if !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("fixture stopped: %w", err)
		}
	default:
	}
	fmt.Println("All Swift checks passed against Go encrypted sync and synthetic provider fixtures.")
	return nil
}
