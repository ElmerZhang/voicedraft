package syncserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

var ErrConflict = errors.New("revision conflict")

type Store struct{ db *sql.DB }

func OpenStore(path string) (*Store, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	// Set permissions before SQLite creates its WAL/SHM companions.
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	err = file.Chmod(0600)
	closeErr := file.Close()
	if err != nil {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	dsn := url.URL{Scheme: "file", Path: filepath.ToSlash(path)}
	query := url.Values{"_pragma": {"busy_timeout(10000)"}, "_txlock": {"immediate"}}
	dsn.RawQuery = query.Encode()
	db, err := sql.Open("sqlite", dsn.String())
	if err != nil {
		return nil, err
	}
	// One connection per process is sufficient for a single vault. BEGIN IMMEDIATE
	// also serializes writers from other processes opening the same database.
	db.SetMaxOpenConns(1)
	for _, statement := range []string{
		"PRAGMA journal_mode=WAL",
		"CREATE TABLE IF NOT EXISTS vault (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, payload TEXT NOT NULL)",
	} {
		if _, err = db.Exec(statement); err != nil {
			_ = db.Close()
			return nil, err
		}
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) Read(ctx context.Context) (Record, error) {
	var record Record
	var payload string
	err := s.db.QueryRowContext(ctx, "SELECT revision, payload FROM vault WHERE id=1").Scan(&record.Revision, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, nil
	}
	if err != nil {
		return Record{}, err
	}
	if record.Revision < 1 || record.Revision > 1<<53 {
		return Record{}, ErrInvalid
	}
	record.Payload, err = decodeEnvelope([]byte(payload))
	return record, err
}

func (s *Store) Write(ctx context.Context, record Record) (Record, error) {
	if record.Revision < 0 || record.Revision >= 1<<53 || record.Payload == nil || record.Payload.Validate() != nil {
		return Record{}, ErrInvalid
	}
	payload, err := json.Marshal(record.Payload)
	if err != nil {
		return Record{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Record{}, err
	}
	defer tx.Rollback()
	var current int64
	err = tx.QueryRowContext(ctx, "SELECT revision FROM vault WHERE id=1").Scan(&current)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Record{}, err
	}
	if record.Revision != current {
		return Record{}, ErrConflict
	}
	record.Revision = current + 1
	_, err = tx.ExecContext(ctx, "INSERT INTO vault(id, revision, payload) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload", record.Revision, string(payload))
	if err != nil {
		return Record{}, err
	}
	if err = tx.Commit(); err != nil {
		return Record{}, err
	}
	return record, nil
}
