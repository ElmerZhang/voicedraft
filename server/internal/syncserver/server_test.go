package syncserver

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const testToken = "synthetic-test-token-with-at-least-32-characters"

func envelope() *Envelope {
	return &Envelope{Version: 1, Algorithm: Algorithm, Iterations: 600_000,
		Salt:       base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16)),
		Ciphertext: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{2}, 100))}
}

func openTestStore(t *testing.T, path string) *Store {
	t.Helper()
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func setup(t *testing.T) (*Store, *Handler, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "private directory", "vault ?#.sqlite3")
	store := openTestStore(t, path)
	handler, err := NewHandler(store, testToken)
	if err != nil {
		t.Fatal(err)
	}
	return store, handler, path
}

func request(handler http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func body(revision int64, payload *Envelope) string {
	data, _ := json.Marshal(Record{Revision: revision, Payload: payload})
	return string(data)
}

func decoded(t *testing.T, response *httptest.ResponseRecorder) Record {
	t.Helper()
	if response.Code != 200 {
		t.Fatalf("unexpected HTTP %d: %s", response.Code, response.Body)
	}
	var record Record
	if err := json.Unmarshal(response.Body.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	return record
}

func TestAuthenticationHealthAndExactPaths(t *testing.T) {
	_, handler, _ := setup(t)
	for _, method := range []string{"GET", "PUT", "DELETE"} {
		if w := request(handler, method, "/v1/sync", body(0, envelope()), "wrong"); w.Code != 401 {
			t.Fatalf("%s: %d", method, w.Code)
		}
	}
	w := request(handler, "GET", "/healthz", "", "")
	if w.Code != 200 || w.Body.String() != `{"protocol":1,"status":"ok"}` {
		t.Fatal(w)
	}
	for _, path := range []string{"/v1/sync?token=ignored", "/v1/sync/", "/v1/%73ync", "/healthz?test"} {
		if w := request(handler, "GET", path, "", testToken); w.Code != 404 {
			t.Fatalf("%s: %d", path, w.Code)
		}
	}
	w = request(handler, "DELETE", "/v1/sync", "", testToken)
	if w.Code != 405 || w.Header().Get("Allow") != "GET, PUT" {
		t.Fatal(w)
	}
	w = request(handler, "GET", "/v1/sync", "", testToken)
	if got := decoded(t, w); got.Revision != 0 || got.Payload != nil {
		t.Fatal(got)
	}
	if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal(w.Header())
	}
}

func TestRoundTripConflictPersistenceAndPermissions(t *testing.T) {
	store, handler, path := setup(t)
	first := envelope()
	saved := decoded(t, request(handler, "PUT", "/v1/sync", body(0, first), testToken))
	if saved.Revision != 1 || !reflect.DeepEqual(saved.Payload, first) {
		t.Fatal(saved)
	}
	second := envelope()
	second.Ciphertext = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{3}, 100))
	if w := request(handler, "PUT", "/v1/sync", body(0, second), testToken); w.Code != 409 {
		t.Fatal(w)
	}
	if got := decoded(t, request(handler, "GET", "/v1/sync", "", testToken)); !reflect.DeepEqual(got, saved) {
		t.Fatal(got)
	}
	saved = decoded(t, request(handler, "PUT", "/v1/sync", body(1, second), testToken))
	if saved.Revision != 2 {
		t.Fatal(saved)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openTestStore(t, path)
	got, err := reopened.Read(context.Background())
	if err != nil || !reflect.DeepEqual(got, saved) {
		t.Fatalf("%+v: %v", got, err)
	}
	for file, mode := range map[string]os.FileMode{path: 0600, filepath.Dir(path): 0700} {
		info, err := os.Stat(file)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != mode {
			t.Fatalf("%s permissions: %o", file, info.Mode().Perm())
		}
	}
}

func TestConcurrentConnectionsHaveOneWinner(t *testing.T) {
	_, _, path := setup(t)
	// Independent connections exercise SQLite locking, not merely the Go pool.
	var handlers []*Handler
	for range 8 {
		handler, err := NewHandler(openTestStore(t, path), testToken)
		if err != nil {
			t.Fatal(err)
		}
		handlers = append(handlers, handler)
	}
	start := make(chan struct{})
	results := make(chan int, len(handlers))
	var group sync.WaitGroup
	for _, handler := range handlers {
		group.Go(func() { <-start; results <- request(handler, "PUT", "/v1/sync", body(0, envelope()), testToken).Code })
	}
	close(start)
	group.Wait()
	close(results)
	counts := map[int]int{}
	for code := range results {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 7 {
		t.Fatal(counts)
	}
}

func TestInvalidRequestsNeverPersist(t *testing.T) {
	_, handler, _ := setup(t)
	valid := body(0, envelope())
	cases := map[string]string{
		"null": "null", "array": "[]", "empty": "{}", "extra": strings.Replace(valid, `"revision":0`, `"revision":0,"apiKey":"secret"`, 1),
		"plaintext":    `{"revision":0,"payload":{"apiKey":"secret"}}`,
		"null payload": `{"revision":0,"payload":null}`, "trailing JSON": valid + "{}",
		"invalid UTF8": strings.Replace(valid, Algorithm, "\xff", 1),
	}
	for _, revision := range []string{"-1", "true", `"0"`, "null", "0.0", "1e0", "9007199254740992", "9223372036854775808"} {
		cases["revision "+revision] = strings.Replace(valid, `"revision":0`, `"revision":`+revision, 1)
	}
	for field, values := range map[string][]any{
		"version": {true, 2, nil, 1.5}, "iterations": {1, "600000", nil},
		"algorithm": {"unknown", nil}, "salt": {"invalid", "AAAAAAAAAAAAAAAAAAAAAA==\n", nil, 42},
		"ciphertext": {"AA==", "@@@@", nil, strings.Repeat("A", 1_333_336)},
		"apiKey":     {"must-not-be-stored"},
	} {
		for i, value := range values {
			var payload map[string]any
			data, _ := json.Marshal(envelope())
			_ = json.Unmarshal(data, &payload)
			payload[field] = value
			data, _ = json.Marshal(map[string]any{"revision": 0, "payload": payload})
			cases[fmt.Sprintf("%s %d", field, i)] = string(data)
		}
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			if w := request(handler, "PUT", "/v1/sync", value, testToken); w.Code != 400 {
				t.Fatalf("HTTP %d", w.Code)
			}
		})
	}
	if got := decoded(t, request(handler, "GET", "/v1/sync", "", testToken)); got.Revision != 0 {
		t.Fatal(got)
	}
}

func TestRequestFramingAndLimits(t *testing.T) {
	_, handler, _ := setup(t)
	cases := []struct {
		name   string
		code   int
		change func(*http.Request)
	}{
		{"type", 415, func(r *http.Request) { r.Header.Set("Content-Type", "text/plain") }},
		{"oversize", 413, func(r *http.Request) { r.ContentLength = MaxBody + 1 }},
		{"empty", 413, func(r *http.Request) { r.ContentLength = 0 }},
		{"unknown size", 413, func(r *http.Request) { r.ContentLength = -1 }},
		{"chunked", 400, func(r *http.Request) { r.TransferEncoding = []string{"chunked"} }},
		{"short", 400, func(r *http.Request) { r.ContentLength++ }},
		{"long", 400, func(r *http.Request) { r.ContentLength-- }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			r := httptest.NewRequest("PUT", "/v1/sync", strings.NewReader(body(0, envelope())))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+testToken)
			test.change(r)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != test.code {
				t.Fatalf("want %d, got %d", test.code, w.Code)
			}
		})
	}
	for _, size := range []int{28, 1_000_000} {
		e := envelope()
		e.Ciphertext = base64.StdEncoding.EncodeToString(make([]byte, size))
		if e.Validate() != nil {
			t.Fatalf("valid boundary rejected: %d", size)
		}
	}
	maximum := envelope()
	maximum.Ciphertext = base64.StdEncoding.EncodeToString(make([]byte, 1_000_000))
	if w := request(handler, "PUT", "/v1/sync", body(0, maximum), testToken); w.Code != 200 {
		t.Fatal(w.Code)
	}
}

func TestStorageFailureIsOpaque(t *testing.T) {
	store, handler, _ := setup(t)
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{"GET", "PUT"} {
		w := request(handler, method, "/v1/sync", body(0, envelope()), testToken)
		if w.Code != 503 || w.Body.String() != `{"error":"Storage unavailable"}` {
			t.Fatal(w)
		}
	}
}

func TestLegacyDatabaseAndTransactionRollback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "vault.sqlite3")
	fixture, err := os.ReadFile("testdata/legacy-vault.db")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, fixture, 0600); err != nil {
		t.Fatal(err)
	}
	store := openTestStore(t, path)
	before, err := store.Read(context.Background())
	if err != nil || before.Revision != 7 || !reflect.DeepEqual(before.Payload, envelope()) {
		t.Fatalf("%+v: %v", before, err)
	}
	_, err = store.Write(context.Background(), Record{Revision: 6, Payload: envelope()})
	if !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = store.Write(ctx, before); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	after, err := store.Write(context.Background(), before)
	if err != nil || after.Revision != 8 {
		t.Fatalf("%+v: %v", after, err)
	}
	// Same legacy SQL schema and payload JSON remain readable after a Go write.
	var revision int64
	var payload string
	if err := store.db.QueryRow("SELECT revision, payload FROM vault WHERE id=1").Scan(&revision, &payload); err != nil {
		t.Fatal(err)
	}
	if revision != 8 {
		t.Fatal(revision)
	}
	var value Envelope
	if err := json.Unmarshal([]byte(payload), &value); err != nil || value != *before.Payload {
		t.Fatal(payload, err)
	}
}

func TestTokenValidation(t *testing.T) {
	for _, token := range []string{"", strings.Repeat("a", 31), testToken + "\n", testToken + "\u2003"} {
		if ValidateToken(token) == nil {
			t.Fatal("invalid token accepted")
		}
	}
	if ValidateToken(testToken) != nil {
		t.Fatal("valid token rejected")
	}
}
