package backup

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestClientEnvironmentKeepsPasswordOutOfDatabaseArgument(t *testing.T) {
	target := Target{URL: "postgres://persona:process-secret@db.example:5432/persona?sslmode=disable"}
	for _, docker := range []bool{false, true} {
		environment := clientEnvironment(target, "another database", docker)
		if len(environment) != 2 || environment[1] != "PGPASSWORD=process-secret" {
			t.Fatalf("client environment = %#v", environment)
		}
		if strings.Contains(environment[0], "process-secret") {
			t.Fatalf("database argument contains password: %q", environment[0])
		}
		if docker && !strings.Contains(environment[0], "127.0.0.1:5432") {
			t.Fatalf("Docker client does not use container loopback: %q", environment[0])
		}
	}
}

func TestRunClientRedactsRealProcessErrors(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX test executable")
	}
	directory := t.TempDir()
	secret := "process-secret"
	rawURL := "postgres://persona:" + secret + "@db.example:5432/persona?sslmode=disable"
	script := "#!/bin/sh\nprintf '%s %s\\n' '" + rawURL + "' '" + secret + "' >&2\nexit 1\n"
	name := filepath.Join(directory, "pg_dump")
	if err := os.WriteFile(name, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	backend := newPostgresBackend()
	err := backend.runClient(context.Background(), Target{URL: rawURL}, "persona", nil, io.Discard, "pg_dump")
	if err == nil {
		t.Fatal("expected the fake client failure")
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), rawURL) {
		t.Fatalf("process error leaked credentials: %q", err)
	}
	if !strings.Contains(err.Error(), "<redacted>") {
		t.Fatalf("process error was not redacted: %q", err)
	}
}

func TestRunClientDockerArgumentsContainNoPassword(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX test executable")
	}
	directory := t.TempDir()
	argsFile := filepath.Join(directory, "args")
	databaseFile := filepath.Join(directory, "database")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" >\"$CAPTURE_ARGS\"\nprintf '%s' \"$PGDATABASE\" >\"$CAPTURE_DATABASE\"\nprintf 'dump'\n"
	if err := os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory)
	t.Setenv("CAPTURE_ARGS", argsFile)
	t.Setenv("CAPTURE_DATABASE", databaseFile)
	backend := newPostgresBackend()
	target := Target{URL: "postgres://persona:process-secret@db.example:5432/persona?sslmode=disable", Container: "disposable-postgres"}
	var stdout bytes.Buffer
	if err := backend.runClient(context.Background(), target, "persona", nil, &stdout, "pg_dump", "--format=custom"); err != nil {
		t.Fatal(err)
	}
	args, _ := os.ReadFile(argsFile)
	database, _ := os.ReadFile(databaseFile)
	if strings.Contains(string(args), "process-secret") || strings.Contains(string(database), "process-secret") {
		t.Fatalf("Docker arguments leak a password: args %q database %q", args, database)
	}
	for _, wanted := range []string{"exec", "--interactive", "--env", "PGPASSWORD", "disposable-postgres", "pg_dump", "--format=custom"} {
		if !strings.Contains(string(args), wanted) {
			t.Errorf("Docker arguments lack %q: %q", wanted, args)
		}
	}
	if stdout.String() != "dump" {
		t.Fatalf("dump stdout = %q", stdout.String())
	}
}

func TestExternalDatabaseDoesNotGuessLocalDockerContainer(t *testing.T) {
	target, err := makeTarget("hub", "postgres://persona:secret@db.example:5432/persona", "", "persona-postgres")
	if err != nil {
		t.Fatal(err)
	}
	if target.DefaultContainer != "" {
		t.Fatalf("external URL guessed container %q", target.DefaultContainer)
	}
	local, err := makeTarget("hub", "postgres://persona:secret@127.0.0.1:5432/persona", "", "persona-postgres")
	if err != nil {
		t.Fatal(err)
	}
	if local.DefaultContainer != "persona-postgres" {
		t.Fatalf("native Docker default was not retained: %q", local.DefaultContainer)
	}
}
