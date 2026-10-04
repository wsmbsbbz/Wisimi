#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
server_pid=''
cleanup() {
    if test -n "$server_pid"; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$check_dir"
}
trap cleanup EXIT
cat > "$check_dir/server.py" <<'PY'
import http.server, pathlib, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/missing.mp3':
            self.send_error(404)
            return
        size = 1048576 if self.path in ('/slow.mp3', '/cancel.mp3') else 1024
        self.send_response(200)
        self.send_header('Content-Type', 'text/html' if self.path == '/html.mp3' else 'application/octet-stream')
        self.send_header('Content-Length', str(size))
        self.end_headers()
        try:
            for _ in range(size // 1024):
                self.wfile.write(b'x' * 1024)
                self.wfile.flush()
                if size > 1024: time.sleep(.002)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$check_dir/server.py" "$check_dir/port" &
server_pid=$!
# Wait for the server's explicit ready signal; Python starts more slowly on a fresh CI runner.
ready_attempt=0
while ! test -s "$check_dir/port"; do
    kill -0 "$server_pid" 2>/dev/null || { echo "Download test server exited before startup" >&2; exit 1; }
    ready_attempt=$((ready_attempt + 1))
    test "$ready_attempt" -lt 300 || { echo "Download test server startup timed out" >&2; exit 1; }
    sleep 0.1
done
cat > "$check_dir/main.swift" <<'SWIFT'
import Foundation
@main struct Check {
    @MainActor static func main() async throws {
        try await DownloadSelfCheck.run(baseURL: URL(string: CommandLine.arguments[1])!)
    }
}
SWIFT
swiftc -D DEBUG -parse-as-library -module-cache-path "$check_dir/cache" \
    Wisimi/Features/Works/DownloadStore.swift Wisimi/Features/Works/DownloadSelfCheck.swift \
    Wisimi/Features/Works/WorksModels.swift Wisimi/Features/Works/ASMRClient.swift \
    Wisimi/Features/Works/AuthSession.swift Wisimi/Shared/Extensions/DurationFormat.swift \
    "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check" "http://127.0.0.1:$(cat "$check_dir/port")"
