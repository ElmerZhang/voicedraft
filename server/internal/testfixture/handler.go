// Package testfixture provides synthetic provider responses for Swift tests.
// It is only linked by the integration-test command, never the sync service.
package testfixture

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
)

type Handler struct {
	Sync   http.Handler
	Leaked atomic.Bool
}

type providerRequest struct {
	Model    string `json:"model"`
	Stream   bool   `json:"stream"`
	Store    *bool  `json:"store"`
	Messages []struct {
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
}

func reply(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" || !strings.HasPrefix(r.URL.Path, "/mock/") {
		h.Sync.ServeHTTP(w, r)
		return
	}
	switch r.URL.Path {
	case "/mock/redirect":
		w.Header().Set("Location", "/mock/leaked")
		w.Header().Set("Content-Length", "0")
		w.WriteHeader(307)
		return
	case "/mock/leaked":
		h.Leaked.Store(true)
		reply(w, 500, map[string]any{})
		return
	case "/mock/rate-limit":
		reply(w, 429, map[string]any{"error": map[string]string{"message": "test-only-key"}})
		return
	}
	if r.URL.Path == "/mock/stream/anthropic" {
		if r.Header.Get("x-api-key") != "test-only-key" {
			reply(w, 401, nil)
			return
		}
	} else if r.Header.Get("Authorization") != "Bearer test-only-key" {
		reply(w, 401, nil)
		return
	}
	var body providerRequest
	if json.NewDecoder(io.LimitReader(r.Body, 2_000_000)).Decode(&body) != nil {
		reply(w, 400, nil)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/mock/stream/") {
		if !body.Stream {
			reply(w, 400, nil)
			return
		}
		var events []string
		switch strings.TrimPrefix(r.URL.Path, "/mock/stream/") {
		case "anthropic":
			events = []string{
				`{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}`,
				`{"type":"content_block_delta","delta":{"type":"text_delta","text":" VoiceDraft"}}`,
				`{"type":"message_delta","delta":{"stop_reason":"end_turn"}}`,
				`{"type":"message_stop"}`,
			}
		case "responses":
			if body.Store == nil || *body.Store {
				reply(w, 400, nil)
				return
			}
			events = []string{
				`{"type":"response.output_text.delta","delta":"你好"}`,
				`{"type":"response.output_text.delta","delta":" VoiceDraft"}`,
				`{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"你好 VoiceDraft"}]}]}}`,
			}
		case "truncated":
			events = []string{`{"choices":[{"delta":{"content":"你好"}}]}`}
		case "chatCompletions":
			events = []string{`{"choices":[{"delta":{"content":"你好"}}]}`, `{"choices":[{"delta":{"content":" VoiceDraft"},"finish_reason":"stop"}]}`}
		default:
			reply(w, 404, nil)
			return
		}
		var wire strings.Builder
		for _, event := range events {
			wire.WriteString("data: " + event + "\n\n")
		}
		data := []byte(wire.String())
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.WriteHeader(200)
		for offset := 0; offset < len(data); offset += 7 {
			// Exercise splits within UTF-8 and SSE/JSON boundaries.
			_, _ = w.Write(data[offset:min(offset+7, len(data))])
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
		}
		return
	}
	if r.URL.Path != "/mock/qwen" {
		reply(w, 404, nil)
		return
	}
	if len(body.Messages) == 0 {
		reply(w, 400, nil)
		return
	}
	content := body.Messages[len(body.Messages)-1].Content
	var text string
	if body.Model == "qwen3-asr-flash" {
		var audio []struct {
			Type       string `json:"type"`
			InputAudio struct {
				Data string `json:"data"`
			} `json:"input_audio"`
		}
		if json.Unmarshal(content, &audio) != nil || len(audio) == 0 || audio[0].Type != "input_audio" || !strings.HasPrefix(audio[0].InputAudio.Data, "data:audio/wav;base64,") {
			reply(w, 400, nil)
			return
		}
		text = "We should ship VoiceDraft tomorrow."
	} else {
		var encoded string
		var input struct {
			Transcript string `json:"transcript"`
		}
		if json.Unmarshal(content, &encoded) != nil || json.Unmarshal([]byte(encoded), &input) != nil || input.Transcript != "We should ship VoiceDraft tomorrow." {
			reply(w, 400, nil)
			return
		}
		text = "Ship VoiceDraft tomorrow."
	}
	reply(w, 200, map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": text}, "finish_reason": "stop"}}})
}
