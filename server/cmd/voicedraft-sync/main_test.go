package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInvalidConfigurationFailsBeforeOpeningDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "unused.sqlite3")
	t.Setenv("VOICEDRAFT_DB", path)
	t.Setenv("VOICEDRAFT_SYNC_TOKEN", "invalid")
	if err := run(); err == nil || !strings.Contains(err.Error(), "VOICEDRAFT_SYNC_TOKEN") {
		t.Fatal(err)
	}
	t.Setenv("VOICEDRAFT_SYNC_TOKEN", strings.Repeat("x", 32))
	for _, port := range []string{"", "abc", "0", "-1", "65536"} {
		t.Setenv("VOICEDRAFT_PORT", port)
		if err := run(); err == nil || !strings.Contains(err.Error(), "VOICEDRAFT_PORT") {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("invalid configuration created a database")
	}
}
