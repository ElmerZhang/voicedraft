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
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"voicedraft/server/internal/syncserver"
)

func main() {
	generateToken := flag.Bool("generate-token", false, "print a new random access token and exit")
	flag.Parse()
	if *generateToken {
		var token [32]byte
		if _, err := rand.Read(token[:]); err != nil {
			fmt.Fprintln(os.Stderr, "Could not generate token")
			os.Exit(1)
		}
		fmt.Println(base64.RawURLEncoding.EncodeToString(token[:]))
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func env(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return value
	}
	return fallback
}

func run() error {
	token := os.Getenv("VOICEDRAFT_SYNC_TOKEN")
	if err := syncserver.ValidateToken(token); err != nil {
		return err
	}
	port := env("VOICEDRAFT_PORT", "8765")
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return errors.New("VOICEDRAFT_PORT must be between 1 and 65535")
	}
	store, err := syncserver.OpenStore(env("VOICEDRAFT_DB", "./data/vault.sqlite3"))
	if err != nil {
		return errors.New("Could not open sync database")
	}
	defer store.Close()
	handler, err := syncserver.NewHandler(store, token)
	if err != nil {
		return err
	}
	server := syncserver.NewHTTPServer(net.JoinHostPort(env("VOICEDRAFT_HOST", "127.0.0.1"), port), handler)
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return errors.New("Could not listen on configured address")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if server.Shutdown(shutdown) != nil {
			_ = server.Close()
		}
	}()
	fmt.Printf("VoiceDraft sync listening on %s\n", listener.Addr())
	err = server.Serve(listener)
	stop()
	<-stopped
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return errors.New("Sync HTTP server stopped unexpectedly")
	}
	return nil
}
