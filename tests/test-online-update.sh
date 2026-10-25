#!/usr/bin/env bash
# Integration test for online timer polling. Run ONLY in an ephemeral CI runner.
set -euo pipefail
[[ "${CI:-}" == "true" ]] || { echo "This test requires CI=true in a disposable runner" >&2; exit 2; }
(( EUID == 0 )) || { echo "Run as root in the disposable runner" >&2; exit 2; }
[[ ! -e /etc/fwmgr && ! -e /var/lib/fwmgr && ! -e /etc/systemd/system/fwmgr-nft.service ]] || {
    echo "Existing FWMgr installation detected; refusing to overwrite it" >&2; exit 2;
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
cleanup() {
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    rm -rf /etc/fwmgr /var/lib/fwmgr "$tmp"
    rm -f /etc/systemd/system/fwmgr-nft.service
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/source" /etc/fwmgr
export TEST_NFT_EXISTS="$tmp/nft-exists" TEST_NFT_FAIL="$tmp/nft-fail" TEST_NFT_LOG="$tmp/nft-log"
: > "$TEST_NFT_LOG"
cat > "$tmp/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
[[ "${*: -1}" == "nftables" ]] || exit 1
printf 'install ok installed'
MOCK
cat > "$tmp/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "is-active" ]]; then
    [[ "$*" == *"nftables.service"* ]]
else
    exit 0
fi
MOCK
cat > "$tmp/bin/nft" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
    [[ -f "$TEST_NFT_EXISTS" ]] || exit 1
    if [[ "${2:-}" == "tables" ]]; then
        printf "table inet fwmgr\n"
        exit 0
    fi
    printf 'table inet fwmgr { chain input { type filter hook input priority 100; policy accept; } }\n'
elif [[ "$1" == "-c" ]]; then
    exit 0
elif [[ "$1" == "-f" ]]; then
    [[ ! -e "$TEST_NFT_FAIL" ]] || exit 1
    printf 'apply\n' >> "$TEST_NFT_LOG"
    touch "$TEST_NFT_EXISTS"
elif [[ "$1" == "delete" ]]; then
    rm -f "$TEST_NFT_EXISTS"
else
    echo "Unexpected nft command: $*" >&2
    exit 1
fi
MOCK
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

cat > "$tmp/server.py" <<'PY'
import http.server
import os
import socketserver
import sys

os.chdir(sys.argv[1])
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[2], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()
PY
printf '203.0.113.2\n198.51.100.0/24\n' > "$tmp/source/list.txt"
python3 "$tmp/server.py" "$tmp/source" "$tmp/port" &
server_pid=$!
for _ in {1..50}; do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
[[ -s "$tmp/port" ]] || { echo "HTTP server failed to start" >&2; exit 1; }

cat > /etc/fwmgr/config <<'CFG'
MODE=blacklist
ACTION=drop
BACKEND=nftables
BLACK_ONLINE_ENABLED=1
WHITE_ONLINE_ENABLED=0
CFG
printf 'http://127.0.0.1:%s/list.txt\n' "$(cat "$tmp/port")" > /etc/fwmgr/blacklist_urls
updates() { wc -l < "$TEST_NFT_LOG"; }
assert_updates() {
    [[ "$(updates)" -eq "$1" ]] || {
        echo "Expected $1 firewall applies, got $(updates)" >&2; exit 1;
    }
}
poll() { bash "$repo/fwmgr.sh" --online-update blacklist; }

poll
assert_updates 1
poll
assert_updates 1

# Reordering and comments must not trigger reapplication.
printf '# same entries, different order\n198.51.100.0/24\n203.0.113.2\n' > "$tmp/source/list.txt"
poll
assert_updates 1

# A genuinely changed normalized list is applied exactly once.
printf '203.0.113.3\n198.51.100.0/24\n' > "$tmp/source/list.txt"
poll
assert_updates 2
poll
assert_updates 2

# Failed apply must remain pending even when the next downloaded file is identical.
printf '203.0.113.4\n198.51.100.0/24\n' > "$tmp/source/list.txt"
touch "$TEST_NFT_FAIL"
if poll; then echo "Expected firewall apply to fail" >&2; exit 1; fi
assert_updates 2
[[ -f /var/lib/fwmgr/online/blacklist.pending ]] || { echo "Missing retry marker" >&2; exit 1; }
rm -f "$TEST_NFT_FAIL"
poll
assert_updates 3
[[ ! -e /var/lib/fwmgr/online/blacklist.pending ]]

# Recover an externally removed nftables table without another list change.
rm -f "$TEST_NFT_EXISTS"
poll
assert_updates 4
echo "PASS: unchanged, reordered, changed, failed/retried, and missing-table cases"
