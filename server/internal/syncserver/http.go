package syncserver

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type Handler struct {
	store       *Store
	tokenDigest [32]byte
}

func ValidateToken(token string) error {
	if utf8.RuneCountInString(token) < 32 || strings.ContainsFunc(token, unicode.IsSpace) {
		return errors.New("VOICEDRAFT_SYNC_TOKEN must have at least 32 characters and no whitespace")
	}
	return nil
}

func NewHandler(store *Store, token string) (*Handler, error) {
	if err := ValidateToken(token); err != nil {
		return nil, err
	}
	return &Handler{store: store, tokenDigest: sha256.Sum256([]byte(token))}, nil
}

// NewHTTPServer applies time/size limits to the production network listener.
func NewHTTPServer(address string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr: address, Handler: handler,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
		// net/http panic logs can contain request details; never log request data.
		ErrorLog: log.New(io.Discard, "", 0),
	}
}

func reply(w http.ResponseWriter, code int, body any) {
	data, err := json.Marshal(body)
	if err != nil {
		code = http.StatusInternalServerError
		data = []byte(`{"error":"Internal error"}`)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_, _ = w.Write(data)
}

func failure(w http.ResponseWriter, code int, message string) {
	reply(w, code, map[string]string{"error": message})
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// RequestURI preserves the existing exact-path contract (no query or aliases).
	if r.Method == http.MethodGet && r.URL.RequestURI() == "/healthz" {
		reply(w, 200, map[string]any{"status": "ok", "protocol": 1})
		return
	}
	header := r.Header.Get("Authorization")
	provided := sha256.Sum256([]byte(strings.TrimPrefix(header, "Bearer ")))
	if !strings.HasPrefix(header, "Bearer ") || subtle.ConstantTimeCompare(provided[:], h.tokenDigest[:]) != 1 {
		failure(w, 401, "Unauthorized")
		return
	}
	if r.URL.RequestURI() != "/v1/sync" {
		failure(w, 404, "Not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		record, err := h.store.Read(r.Context())
		if err != nil {
			failure(w, 503, "Storage unavailable")
			return
		}
		reply(w, 200, record)
	case http.MethodPut:
		h.put(w, r)
	default:
		w.Header().Set("Allow", "GET, PUT")
		failure(w, 405, "Method not allowed")
	}
}

func (h *Handler) put(w http.ResponseWriter, r *http.Request) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		failure(w, 415, "Use application/json")
		return
	}
	if len(r.TransferEncoding) != 0 || r.Header.Get("Transfer-Encoding") != "" {
		failure(w, 400, "Chunked uploads are not supported")
		return
	}
	if r.ContentLength <= 0 || r.ContentLength > MaxBody {
		failure(w, 413, "Invalid request size")
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, r.ContentLength+1))
	if err != nil || int64(len(data)) != r.ContentLength {
		failure(w, 400, "Invalid request or encrypted envelope")
		return
	}
	record, err := decodeWrite(data)
	if err != nil {
		failure(w, 400, "Invalid request or encrypted envelope")
		return
	}
	saved, err := h.store.Write(r.Context(), record)
	switch {
	case errors.Is(err, ErrConflict):
		failure(w, 409, "Revision conflict; fetch before retrying")
	case errors.Is(err, ErrInvalid):
		failure(w, 400, "Invalid request or encrypted envelope")
	case err != nil:
		failure(w, 503, "Storage unavailable")
	default:
		reply(w, 200, saved)
	}
}
