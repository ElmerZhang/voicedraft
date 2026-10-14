package testfixture

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSwiftProviderFixtureContract(t *testing.T) {
	h := &Handler{Sync: http.NotFoundHandler()}
	for _, adapter := range []string{"chatCompletions", "anthropic", "responses", "truncated"} {
		t.Run(adapter, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/mock/stream/"+adapter, strings.NewReader(`{"stream":true,"store":false}`))
			r.Header.Set("Authorization", "Bearer test-only-key")
			r.Header.Set("x-api-key", "test-only-key")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 200 || w.Header().Get("Content-Type") != "text/event-stream" {
				t.Fatal(w)
			}
			if !strings.Contains(w.Body.String(), "你好") || !strings.HasSuffix(w.Body.String(), "\n\n") || !w.Flushed {
				t.Fatal(w.Body.String())
			}
			for _, event := range strings.Split(strings.TrimSpace(w.Body.String()), "\n\n") {
				if !json.Valid([]byte(strings.TrimPrefix(event, "data: "))) {
					t.Fatal(event)
				}
			}
			if adapter != "truncated" && !strings.Contains(w.Body.String(), " VoiceDraft") {
				t.Fatal(w.Body.String())
			}
		})
	}
	for _, test := range []struct{ body, output string }{
		{`{"model":"qwen3-asr-flash","messages":[{"content":[{"type":"input_audio","input_audio":{"data":"data:audio/wav;base64,AQID"}}]}]}`, "We should ship VoiceDraft tomorrow."},
		{`{"model":"qwen-plus","messages":[{"content":"{\"transcript\":\"We should ship VoiceDraft tomorrow.\"}"}]}`, "Ship VoiceDraft tomorrow."},
	} {
		r := httptest.NewRequest("POST", "/mock/qwen", strings.NewReader(test.body))
		r.Header.Set("Authorization", "Bearer test-only-key")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || !strings.Contains(w.Body.String(), test.output) {
			t.Fatal(w)
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/mock/redirect", nil))
	if w.Code != 307 || w.Header().Get("Location") != "/mock/leaked" || h.Leaked.Load() {
		t.Fatal(w)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", "/mock/leaked", nil))
	if !h.Leaked.Load() {
		t.Fatal("redirect following was not detected")
	}
}
