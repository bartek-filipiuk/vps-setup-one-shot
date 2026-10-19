// Go fixture for vps-setup-one-shot: net/http plus Postgres through DATABASE_URL.
// Health contract: GET /api/health answers 200 {"status":"ok","db":"ok"} when the app and its
// database work, 503 {"status":"error","db":"error"} otherwise, with no error details.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func port() string {
	if p := os.Getenv("PORT"); p != "" {
		return p
	}
	return "8080"
}

// migrateOrExit mirrors starter/lib/db.ts: the database may still be booting, so retry
// briefly, then exit so the container restarts instead of serving without a schema.
func migrateOrExit(db *sql.DB) {
	const attempts = 10
	for i := 1; i <= attempts; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, err := db.ExecContext(ctx, `create table if not exists hits (
			id bigint generated always as identity primary key,
			created_at timestamptz not null default now()
		)`)
		cancel()
		if err == nil {
			log.Print("db: schema ready")
			return
		}
		log.Printf("db: migrate attempt %d/%d failed: %v", i, attempts, err)
		time.Sleep(3 * time.Second)
	}
	os.Exit(1)
}

func writeJSON(w http.ResponseWriter, code int, v map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "GET the local health route and exit 0 when it answers 200")
	flag.Parse()
	if *healthcheck {
		// distroless has no shell or wget, so the image's HEALTHCHECK runs the binary itself.
		c := http.Client{Timeout: 3 * time.Second}
		resp, err := c.Get("http://localhost:" + port() + "/api/health")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	db, err := sql.Open("pgx", os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	db.SetMaxOpenConns(5)
	migrateOrExit(db)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		var one int
		// The schema exists, not just a connection.
		if err := db.QueryRowContext(ctx, "select 1 from hits limit 1").Scan(&one); err != nil && err != sql.ErrNoRows {
			log.Printf("health: db check failed: %v", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "error", "db": "error"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "db": "ok"})
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "go fixture for vps-setup-one-shot")
	})

	// ":PORT" listens on every address, IPv6 (::) included: Coolify's health check calls localhost.
	srv := &http.Server{Addr: ":" + port(), Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("listening on :%s", port())
	log.Fatal(srv.ListenAndServe())
}
