package backup

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nwverse/persona/server/internal/secretkey"
)

// TestPostgresWholeInstallRoundTrip runs only against an explicitly provided
// disposable server. It never uses the default runtime directory or a database
// named by the real hub configuration.
func TestPostgresWholeInstallRoundTrip(t *testing.T) {
	base := os.Getenv("PERSONA_TEST_DATABASE_URL")
	container := os.Getenv("PERSONA_TEST_POSTGRES_CONTAINER")
	if base == "" {
		t.Skip("set PERSONA_TEST_DATABASE_URL and optionally PERSONA_TEST_POSTGRES_CONTAINER for disposable PostgreSQL verification")
	}
	if container == "" {
		if _, err := exec.LookPath("pg_dump"); err != nil {
			t.Skip("pg_dump is unavailable; set PERSONA_TEST_POSTGRES_CONTAINER")
		}
		if _, err := exec.LookPath("pg_restore"); err != nil {
			t.Skip("pg_restore is unavailable; set PERSONA_TEST_POSTGRES_CONTAINER")
		}
	}
	random := make([]byte, 6)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	id := hex.EncodeToString(random)
	hubName := "pb_it_hub_" + id
	managerName := "pb_it_manager_" + id + "_" + strings.Repeat("m", 35)
	if len(managerName) > 63 {
		t.Fatal("test manager database name exceeds PostgreSQL's limit")
	}
	hubURL, err := withDatabase(base, hubName)
	if err != nil {
		t.Fatal(err)
	}
	managerURL, err := withDatabase(base, managerName)
	if err != nil {
		t.Fatal(err)
	}
	hub := Target{Part: "hub", URL: hubURL, Database: hubName, Container: container, DefaultContainer: container}
	manager := Target{Part: "manager", URL: managerURL, Database: managerName, Container: container, DefaultContainer: container}
	backend := newPostgresBackend()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	previousNames := make(map[Target][]string)
	for _, target := range []Target{hub, manager} {
		if err := backend.Create(ctx, target, target.Database); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), time.Minute)
		defer cleanupCancel()
		for _, target := range []Target{hub, manager} {
			_ = backend.Drop(cleanupCtx, target, target.Database)
			for _, name := range previousNames[target] {
				_ = backend.Drop(cleanupCtx, target, name)
			}
		}
	})

	managerKey := []byte(strings.Repeat("k", secretkey.Size))
	for _, item := range []struct {
		target  Target
		part    string
		version int
	}{
		{hub, "hub", 1}, {manager, "manager", 430},
	} {
		conn, err := backend.connect(ctx, item.target, item.target.Database)
		if err != nil {
			t.Fatal(err)
		}
		statements := []string{
			`CREATE TABLE schema_migrations (version integer, name text, part text)`,
			`INSERT INTO schema_migrations VALUES ($1, $2, $3)`,
			`CREATE TABLE backup_sample (id integer PRIMARY KEY, value text)`,
			`INSERT INTO backup_sample VALUES (1, 'original')`,
		}
		params := [][]any{{}, {item.version, "0001_test.sql", item.part}, {}, {}}
		if item.target.Part == "manager" {
			statements = append(statements, `CREATE TABLE sealing_key (fingerprint text)`, `INSERT INTO sealing_key VALUES ($1)`)
			params = append(params, []any{}, []any{secretkey.Fingerprint(managerKey)})
		}
		for index, statement := range statements {
			if _, err := conn.Exec(ctx, statement, params[index]...); err != nil {
				closeConn(ctx, conn)
				t.Fatal(err)
			}
		}
		closeConn(ctx, conn)
	}

	root := t.TempDir()
	home := filepath.Join(root, "runtime")
	output := filepath.Join(root, "out", "install.backup")
	writeFixtureFile(t, filepath.Join(home, "hub.json"), []byte(`{"database_url":"`+hubURL+`","token":"disposable-token"}`))
	writeFixtureFile(t, filepath.Join(home, "managers", "assistant", "manager.json"), []byte(`{"database_name":"`+managerName+`"}`))
	writeFixtureFile(t, filepath.Join(home, "secret.key"), []byte(strings.Repeat("h", secretkey.Size)))
	writeFixtureFile(t, filepath.Join(home, "managers", "assistant", "secret.key"), managerKey)
	writeFixtureFile(t, filepath.Join(home, "data", "fact.md"), []byte("disposable knowledge"))
	operator := &Operator{backend: backend, now: time.Now, random: rand.Reader}
	if _, err := operator.Create(ctx, Options{Home: home, Output: output, WritesQuiesced: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := operator.Verify(ctx, Options{Home: home, Bundle: output}); err != nil {
		t.Fatal(err)
	}
	conn, err := backend.connect(ctx, hub, hub.Database)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `UPDATE backup_sample SET value = 'changed' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	closeConn(ctx, conn)
	writeFixtureFile(t, filepath.Join(home, "data", "fact.md"), []byte("changed knowledge"))
	result, err := operator.Restore(ctx, Options{Home: home, Bundle: output, WritesQuiesced: true})
	if err != nil {
		t.Fatal(err)
	}
	previousNames[hub] = append(previousNames[hub], result.PreviousHubDB)
	previousNames[manager] = append(previousNames[manager], result.PreviousManagerDB)
	for _, item := range []struct {
		target Target
		want   string
	}{{hub, "original"}, {Target{Part: "hub", URL: hubURL, Database: result.PreviousHubDB, Container: container, DefaultContainer: container}, "changed"}} {
		conn, err := backend.connect(ctx, item.target, item.target.Database)
		if err != nil {
			t.Fatal(err)
		}
		var got string
		if err := conn.QueryRow(ctx, `SELECT value FROM backup_sample WHERE id = 1`).Scan(&got); err != nil {
			closeConn(ctx, conn)
			t.Fatal(err)
		}
		closeConn(ctx, conn)
		if got != item.want {
			t.Errorf("database %s value = %q, want %q", item.target.Database, got, item.want)
		}
	}
	raw, err := os.ReadFile(filepath.Join(home, "data", "fact.md"))
	if err != nil || string(raw) != "disposable knowledge" {
		t.Errorf("restored knowledge = %q, %v", raw, err)
	}
}
