// Package syncserver implements VoiceDraft's opaque, single-vault sync protocol.
package syncserver

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

const MaxBody = 1_400_000
const Algorithm = "PBKDF2-SHA256+AES-256-GCM"

var ErrInvalid = errors.New("invalid request or encrypted envelope")

type Envelope struct {
	Version    int    `json:"version"`
	Algorithm  string `json:"algorithm"`
	Iterations int    `json:"iterations"`
	Salt       string `json:"salt"`
	Ciphertext string `json:"ciphertext"`
}

type Record struct {
	Revision int64     `json:"revision"`
	Payload  *Envelope `json:"payload"`
}

func (e Envelope) Validate() error {
	if e.Version != 1 || e.Algorithm != Algorithm || e.Iterations != 600_000 {
		return ErrInvalid
	}
	// Go's base64 decoder ignores CR/LF; the protocol does not allow them.
	if strings.ContainsAny(e.Salt+e.Ciphertext, "\r\n") {
		return ErrInvalid
	}
	salt, err := base64.StdEncoding.DecodeString(e.Salt)
	if err != nil || len(salt) != 16 {
		return ErrInvalid
	}
	cipher, err := base64.StdEncoding.DecodeString(e.Ciphertext)
	if err != nil || len(cipher) < 28 || len(cipher) > 1_000_000 {
		return ErrInvalid
	}
	return nil
}

func object(data []byte, keys ...string) (map[string]json.RawMessage, error) {
	var value map[string]json.RawMessage
	if !utf8.Valid(data) || json.Unmarshal(data, &value) != nil || len(value) != len(keys) {
		return nil, ErrInvalid
	}
	for _, key := range keys {
		if _, ok := value[key]; !ok {
			return nil, ErrInvalid
		}
	}
	return value, nil
}

func decodeEnvelope(data []byte) (*Envelope, error) {
	if _, err := object(data, "version", "algorithm", "iterations", "salt", "ciphertext"); err != nil {
		return nil, err
	}
	var envelope Envelope
	if json.Unmarshal(data, &envelope) != nil || envelope.Validate() != nil {
		return nil, ErrInvalid
	}
	return &envelope, nil
}

func decodeWrite(data []byte) (Record, error) {
	value, err := object(data, "revision", "payload")
	if err != nil {
		return Record{}, err
	}
	// Parse the JSON number as an integer, rejecting null, booleans and floats.
	revision, err := strconv.ParseInt(string(value["revision"]), 10, 64)
	if err != nil || revision < 0 || revision >= 1<<53 {
		return Record{}, ErrInvalid
	}
	payload, err := decodeEnvelope(value["payload"])
	return Record{Revision: revision, Payload: payload}, err
}
