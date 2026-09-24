#!/usr/bin/env bash
# FireWall Manager v0.2.0 by MaXaoH
# Ubuntu-oriented interactive manager for host INPUT filtering via UFW or nftables.

set -uo pipefail

VERSION="0.2.0"
FORMAT_VERSION="2"
APP_TITLE="FireWall Manager v${VERSION} by MaXaoH"

STATE_DIR="/etc/fwmgr"
CONFIG_FILE="${STATE_DIR}/config"
BLACKLIST_FILE="${STATE_DIR}/blacklist"
WHITELIST_FILE="${STATE_DIR}/whitelist"
BLACK_URLS_FILE="${STATE_DIR}/blacklist_urls"
WHITE_URLS_FILE="${STATE_DIR}/whitelist_urls"
ONLINE_ROOT="/var/lib/fwmgr/online"
ONLINE_BLACK_DIR="${ONLINE_ROOT}/blacklist"
ONLINE_WHITE_DIR="${ONLINE_ROOT}/whitelist"
INSTALL_DIR="/usr/local/lib/fwmgr"
INSTALL_SCRIPT="${INSTALL_DIR}/fwmgr.sh"
LEGACY_RUNTIME_SCRIPT="${INSTALL_DIR}/fwmgr-runtime"
ONLINE_MAX_BYTES=10485760
ONLINE_MAX_ENTRIES=200000
NFT_FILE="${STATE_DIR}/fwmgr.nft"
BACKUP_ROOT="/var/lib/fwmgr/backups"
LOCK_FILE="/run/lock/fwmgr.lock"
COMMAND_PATH="/usr/local/bin/fwmgr"
UPDATE_CACHE_DIR="/var/cache/fwmgr"
UPDATE_CACHE_FILE="${UPDATE_CACHE_DIR}/update-check"
UPDATE_CACHE_TTL=21600
# Перед публикацией при необходимости измените только эту строку.
GITHUB_REPOSITORY="MaXa0H/fwmgr"
RELEASE_BASE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download"
LATEST_VERSION=""
UPDATE_AVAILABLE=0
NFT_UNIT="/etc/systemd/system/fwmgr-nft.service"
ONLINE_BLACK_SERVICE="/etc/systemd/system/fwmgr-online-blacklist.service"
ONLINE_BLACK_TIMER="/etc/systemd/system/fwmgr-online-blacklist.timer"
ONLINE_WHITE_SERVICE="/etc/systemd/system/fwmgr-online-whitelist.service"
ONLINE_WHITE_TIMER="/etc/systemd/system/fwmgr-online-whitelist.timer"
NFT_TABLE_FAMILY="inet"
NFT_TABLE_NAME="fwmgr"
UFW_CHAIN="fwmgr-input"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_GRAY=$'\033[90m'
    C_BOLD=$'\033[1m'
else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_GRAY="" C_BOLD=""
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%b%s%b\n' "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%b%s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%b%s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%b%s%b\n' "$C_RED" "$*" "$C_RESET" >&2; }
gray() { printf '%b%s%b\n' "$C_GRAY" "$*" "$C_RESET"; }

pause_screen() {
    printf '\n'
    read -r -p "Нажмите Enter для продолжения..." _ || true
}

confirm() {
    local prompt="${1:-Подтвердить?}"
    local ans
    read -r -p "$prompt [y/N]: " ans || return 1
    case "${ans,,}" in
        y|yes|д|да) return 0 ;;
        *) return 1 ;;
    esac
}

SOURCE_TOKEN="${BASH_SOURCE[0]:-}"
SOURCE_PATH=""
SOURCE_IS_FILE=0
if [[ -n "$SOURCE_TOKEN" && -f "$SOURCE_TOKEN" ]]; then
    SOURCE_PATH="$(readlink -f -- "$SOURCE_TOKEN" 2>/dev/null || printf '%s' "$SOURCE_TOKEN")"
    SOURCE_IS_FILE=1
fi

need_root() {
    if (( EUID == 0 )); then
        return 0
    fi
    if (( SOURCE_IS_FILE )) && command -v sudo >/dev/null 2>&1; then
        exec sudo -- env SSH_CONNECTION="${SSH_CONNECTION:-}" SSH_CLIENT="${SSH_CLIENT:-}" "$SOURCE_PATH" "$@"
    fi
    err "Для установки/работы FWMgr требуются права root. Запустите команду через sudo."
    exit 1
}

RUN_MODE="interactive"
UPDATE_KIND=""
case "${1:-}" in
    --online-update)
        RUN_MODE="online-update"
        UPDATE_KIND="${2:-}"
        [[ "$UPDATE_KIND" =~ ^(blacklist|whitelist)$ ]] || { err "Использование: fwmgr --online-update blacklist|whitelist"; exit 2; }
        ;;
    --install) RUN_MODE="install" ;;
    --update) RUN_MODE="self-update" ;;
    --uninstall) RUN_MODE="uninstall" ;;
    --version|-V)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
esac

need_root "$@"

if ! command -v flock >/dev/null 2>&1; then
    if [[ "$RUN_MODE" == "install" ]] && command -v apt-get >/dev/null 2>&1; then
        info "Установка зависимости util-linux (flock)..."
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux || { err "Не удалось установить util-linux."; exit 1; }
    else
        err "Не найдена команда flock (пакет util-linux)."
        exit 1
    fi
fi

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    if [[ "$RUN_MODE" == "online-update" ]]; then
        # Интерактивный экземпляр имеет приоритет; таймер попробует снова позднее.
        exit 0
    fi
    err "FWMgr уже запущен в другом процессе."
    exit 1
fi

SCRIPT_PATH="${SOURCE_PATH:-$INSTALL_SCRIPT}"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
TMP_DIR="$(mktemp -d /tmp/fwmgr.XXXXXX)"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

MODE="off"
ACTION="drop"
BACKEND=""
UFW_ENABLED_BY_FWMGR="0"
BLACK_ONLINE_ENABLED="0"
WHITE_ONLINE_ENABLED="0"
BLACK_UPDATE_MINUTES="1440"
WHITE_UPDATE_MINUTES="1440"
DIRTY=0
CURRENT_IP=""

BLACKLIST=()
WHITELIST=()
BLACK_URLS=()
WHITE_URLS=()
ONLINE_BLACKLIST=()
ONLINE_WHITELIST=()
SAVED_BLACKLIST=()
SAVED_WHITELIST=()
SAVED_BLACK_URLS=()
SAVED_WHITE_URLS=()
SAVED_MODE="off"
SAVED_ACTION="drop"
SAVED_BACKEND=""
SAVED_UFW_ENABLED_BY_FWMGR="0"
SAVED_BLACK_ONLINE_ENABLED="0"
SAVED_WHITE_ONLINE_ENABLED="0"
SAVED_BLACK_UPDATE_MINUTES="1440"
SAVED_WHITE_UPDATE_MINUTES="1440"

UFW_INSTALLED=0
NFT_INSTALLED=0
UFW_ACTIVE=0
NFT_SERVICE_ACTIVE=0
FIREWALLD_ACTIVE=0
NETFILTER_PERSISTENT_ACTIVE=0
DOCKER_ACTIVE=0
FAIL2BAN_ACTIVE=0
HAS_CONFLICT=0
CONFLICT_TEXT=""
RESOLVED_BACKEND=""

clear_screen() {
    if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear; else printf '\n'; fi
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

version_is_newer() {
    local a="${1#v}" b="${2#v}"
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$a" gt "$b"
        return
    fi
    [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

extract_script_version() {
    local file="$1" v
    [[ -f "$file" ]] || return 1
    v="$(grep -m1 -E '^VERSION="[^"]+"$' "$file" 2>/dev/null | sed -E 's/^VERSION="([^"]+)"$/\1/' || true)"
    [[ -n "$v" ]] || return 1
    printf '%s\n' "$v"
}

download_url() {
    local url="$1" dest="$2"
    rm -f -- "$dest"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 3 --max-time 12 --retry 1 -o "$dest" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=12 --tries=2 -O "$dest" "$url" && return 0
    fi
    rm -f -- "$dest"
    return 1
}

download_latest_script() {
    local dest="$1" vfile="$TMP_DIR/latest.VERSION"
    local latest embedded
    download_url "${RELEASE_BASE_URL}/VERSION" "$vfile" || { err "Не удалось получить VERSION с GitHub."; return 1; }
    latest="$(tr -d ' \t\r\n' < "$vfile")"
    [[ "$latest" =~ ^[0-9]+([.][0-9A-Za-z+-]+)+$ ]] || { err "Некорректный VERSION в релизе: $latest"; return 1; }
    download_url "${RELEASE_BASE_URL}/fwmgr.sh" "$dest" || { err "Не удалось скачать fwmgr.sh с GitHub."; return 1; }
    bash -n "$dest" || { err "Скачанный fwmgr.sh не прошёл bash -n."; return 1; }
    embedded="$(extract_script_version "$dest" || true)"
    [[ "$embedded" == "$latest" ]] || { err "Версия в fwmgr.sh ($embedded) не совпадает с VERSION ($latest)."; return 1; }

    LATEST_VERSION="$latest"
    return 0
}

installed_version() {
    extract_script_version "$INSTALL_SCRIPT" 2>/dev/null || true
}

ensure_runtime_dependencies() {
    local -a pkgs=()
    command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
    command -v flock >/dev/null 2>&1 || pkgs+=(util-linux)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        pkgs+=(curl ca-certificates)
    fi
    ((${#pkgs[@]})) || return 0
    command -v apt-get >/dev/null 2>&1 || { err "Не хватает зависимостей: ${pkgs[*]}. apt-get не найден."; return 1; }
    info "Установка зависимостей FWMgr: ${pkgs[*]}"
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1
}

install_system_script() {
    local source="$1" allow_downgrade="${2:-0}" srcver oldver tmp
    [[ -f "$source" ]] || { err "Источник установки не найден: $source"; return 1; }
    bash -n "$source" || { err "Устанавливаемый скрипт не прошёл bash -n."; return 1; }
    srcver="$(extract_script_version "$source" || true)"
    [[ -n "$srcver" ]] || { err "Не удалось определить VERSION устанавливаемого скрипта."; return 1; }
    oldver="$(installed_version)"
    if [[ -n "$oldver" && "$allow_downgrade" != "1" ]] && version_is_newer "$oldver" "$srcver"; then
        warn "Установленная версия v${oldver} новее запускаемой v${srcver}; downgrade отменён."
        return 2
    fi

    mkdir -p "$INSTALL_DIR" "$(dirname "$COMMAND_PATH")"
    tmp="$(mktemp "${INSTALL_DIR}/.fwmgr.XXXXXX")" || return 1
    if ! install -m 0755 "$source" "$tmp"; then rm -f "$tmp"; return 1; fi
    mv -f "$tmp" "$INSTALL_SCRIPT"

    # Миграция v0.1: раньше /usr/local/bin/fwmgr был копией, а таймеры использовали fwmgr-runtime.
    rm -f "$COMMAND_PATH"
    ln -s "$INSTALL_SCRIPT" "$COMMAND_PATH" || return 1
    rm -f "$LEGACY_RUNTIME_SCRIPT"
    if [[ -f "$ONLINE_BLACK_SERVICE" ]]; then sed -i -E "s#^ExecStart=.* --online-update blacklist#ExecStart=${INSTALL_SCRIPT} --online-update blacklist#" "$ONLINE_BLACK_SERVICE"; fi
    if [[ -f "$ONLINE_WHITE_SERVICE" ]]; then sed -i -E "s#^ExecStart=.* --online-update whitelist#ExecStart=${INSTALL_SCRIPT} --online-update whitelist#" "$ONLINE_WHITE_SERVICE"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
    rm -f "$UPDATE_CACHE_FILE" 2>/dev/null || true
    if ! ensure_runtime_dependencies; then
        warn "FWMgr установлен, но не все runtime-зависимости удалось установить."
        return 1
    fi

    if [[ -n "$oldver" && "$oldver" != "$srcver" ]]; then
        ok "FWMgr обновлён: v${oldver} -> v${srcver}."
    elif [[ -n "$oldver" ]]; then
        ok "FWMgr v${srcver} переустановлен."
    else
        ok "FWMgr v${srcver} установлен. Команда: fwmgr"
    fi
    return 0
}

install_requested_version() {
    local src="$SOURCE_PATH" downloaded="$TMP_DIR/fwmgr-install.sh"
    if (( SOURCE_IS_FILE )) && [[ -f "$src" ]]; then
        install_system_script "$src"
        return $?
    fi
    info "Получение последнего стабильного релиза FWMgr..."
    download_latest_script "$downloaded" || return 1
    install_system_script "$downloaded"
}

check_for_updates() {
    local force="${1:-0}" now checked=0 cached="" vfile="$TMP_DIR/check.VERSION"
    now="$(date +%s)"
    if [[ -f "$UPDATE_CACHE_FILE" ]]; then
        checked="$(grep -m1 '^CHECKED=' "$UPDATE_CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)"
        cached="$(grep -m1 '^LATEST=' "$UPDATE_CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)"
        [[ "$checked" =~ ^[0-9]+$ ]] || checked=0
    fi
    if [[ "$force" != "1" && -n "$cached" && $((now-checked)) -lt $UPDATE_CACHE_TTL ]]; then
        LATEST_VERSION="$cached"
    else
        if download_url "${RELEASE_BASE_URL}/VERSION" "$vfile"; then
            cached="$(tr -d ' \t\r\n' < "$vfile")"
            if [[ "$cached" =~ ^[0-9]+([.][0-9A-Za-z+-]+)+$ ]]; then
                LATEST_VERSION="$cached"
                mkdir -p "$UPDATE_CACHE_DIR"
                printf 'CHECKED=%s\nLATEST=%s\n' "$now" "$cached" > "$UPDATE_CACHE_FILE"
                chmod 600 "$UPDATE_CACHE_FILE" 2>/dev/null || true
            fi
        elif [[ -n "$cached" ]]; then
            LATEST_VERSION="$cached"
        fi
    fi
    UPDATE_AVAILABLE=0
    [[ -n "$LATEST_VERSION" ]] && version_is_newer "$LATEST_VERSION" "$VERSION" && UPDATE_AVAILABLE=1
    return 0
}

print_title() {
    printf '%b%s%b' "$C_BOLD" "$APP_TITLE" "$C_RESET"
    if (( UPDATE_AVAILABLE )); then
        printf '    %b[доступна v%s]%b' "$C_YELLOW" "$LATEST_VERSION" "$C_RESET"
    fi
    printf '\n\n'
}

self_update_from_github() {
    local downloaded="$TMP_DIR/fwmgr-update.sh" newver
    info "Проверка последнего стабильного релиза..."
    if ! download_latest_script "$downloaded"; then return 1; fi
    newver="$LATEST_VERSION"
    if ! version_is_newer "$newver" "$VERSION"; then
        ok "Установлена актуальная версия FWMgr v${VERSION}."
        check_for_updates 1 >/dev/null 2>&1 || true
        return 0
    fi
    install_system_script "$downloaded" || return 1
    return 0
}

normalize_entry() {
    python3 - "$1" <<'PY'
import ipaddress, sys
s=sys.argv[1].strip()
try:
    if '/' in s:
        n=ipaddress.ip_network(s, strict=False)
        if n.prefixlen == n.max_prefixlen:
            print(n.network_address.compressed)
        else:
            print(n.with_prefixlen)
    else:
        print(ipaddress.ip_address(s).compressed)
except ValueError:
    sys.exit(1)
PY
}

is_ip_address() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try: ipaddress.ip_address(sys.argv[1]); sys.exit(0)
except ValueError: sys.exit(1)
PY
}

entry_ip_version() {
    python3 - "$1" <<'PY'
import ipaddress,sys
x=sys.argv[1]
try:
    o=ipaddress.ip_network(x, strict=False) if '/' in x else ipaddress.ip_address(x)
    print(o.version)
except ValueError:
    sys.exit(1)
PY
}

entry_contains_ip() {
    local entry="$1" ip="$2"
    python3 - "$entry" "$ip" <<'PY' >/dev/null 2>&1
import ipaddress,sys
try:
    e=sys.argv[1]; ip=ipaddress.ip_address(sys.argv[2])
    net=ipaddress.ip_network(e, strict=False) if '/' in e else ipaddress.ip_network(e + ('/32' if ip.version==4 else '/128'), strict=False)
    sys.exit(0 if net.version == ip.version and ip in net else 1)
except ValueError:
    sys.exit(1)
PY
}

sort_array() {
    local arr_name="$1"
    local -n arr="$arr_name"
    ((${#arr[@]})) || return 0
    mapfile -t arr < <(printf '%s\n' "${arr[@]}" | python3 -c '
import ipaddress,sys
rows=[]
for s in sys.stdin:
 s=s.strip()
 if not s: continue
 o=ipaddress.ip_network(s, strict=False) if "/" in s else ipaddress.ip_network(s + ("/32" if ":" not in s else "/128"), strict=False)
 rows.append((o.version, int(o.network_address), o.prefixlen, s))
for *_,s in sorted(rows): print(s)
')
}

array_has_exact() {
    local arr_name="$1" needle="$2" x
    local -n arr="$arr_name"
    for x in "${arr[@]}"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

array_contains_ip() {
    local arr_name="$1" ip="$2" x
    local -n arr="$arr_name"
    [[ -n "$ip" ]] || return 1
    for x in "${arr[@]}"; do entry_contains_ip "$x" "$ip" && return 0; done
    return 1
}

remove_entries_containing_ip() {
    local arr_name="$1" ip="$2"
    local -n arr="$arr_name"
    local out=() x removed=0
    for x in "${arr[@]}"; do
        if entry_contains_ip "$x" "$ip"; then
            removed=$((removed+1))
        else
            out+=("$x")
        fi
    done
    arr=("${out[@]}")
    REMOVE_ENTRIES_COUNT="$removed"
}

detect_current_ip() {
    local candidate=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        candidate="${SSH_CONNECTION%% *}"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        candidate="${SSH_CLIENT%% *}"
    fi
    if [[ -n "$candidate" ]] && is_ip_address "$candidate"; then
        CURRENT_IP="$(normalize_entry "$candidate")"
    else
        CURRENT_IP=""
    fi
}

load_list_file() {
    local file="$1" arr_name="$2" line norm
    local -n arr="$arr_name"
    arr=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        [[ -n "${line//[[:space:]]/}" ]] || continue
        if norm="$(normalize_entry "$line" 2>/dev/null)"; then
            array_has_exact "$arr_name" "$norm" || arr+=("$norm")
        fi
    done < "$file"
    sort_array "$arr_name"
}

validate_online_url() {
    python3 - "$1" <<'PYURL' >/dev/null 2>&1
import sys, urllib.parse
u=urllib.parse.urlsplit(sys.argv[1].strip())
if u.scheme not in ('http','https') or not u.hostname or u.username or u.password:
    raise SystemExit(1)
raise SystemExit(0)
PYURL
}

url_hash() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

load_url_file() {
    local file="$1" arr_name="$2" line
    local -n arr="$arr_name"
    arr=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        [[ -n "$line" ]] || continue
        if validate_online_url "$line" && ! array_has_exact "$arr_name" "$line"; then
            arr+=("$line")
        fi
    done < "$file"
}

online_cache_dir() {
    [[ "$1" == "blacklist" ]] && printf '%s' "$ONLINE_BLACK_DIR" || printf '%s' "$ONLINE_WHITE_DIR"
}

load_online_cache() {
    local kind="$1" urls_name out_name dir url h line norm
    if [[ "$kind" == "blacklist" ]]; then
        urls_name="BLACK_URLS"; out_name="ONLINE_BLACKLIST"
    else
        urls_name="WHITE_URLS"; out_name="ONLINE_WHITELIST"
    fi
    local -n urls="$urls_name" out="$out_name"
    out=()
    dir="$(online_cache_dir "$kind")"
    for url in "${urls[@]}"; do
        h="$(url_hash "$url")"
        [[ -f "$dir/${h}.list" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            if norm="$(normalize_entry "$line" 2>/dev/null)"; then
                array_has_exact "$out_name" "$norm" || out+=("$norm")
            fi
        done < "$dir/${h}.list"
    done
    sort_array "$out_name"
}

build_effective_list() {
    local kind="$1" out_name="$2" manual_name online_name enabled x
    [[ "$kind" == "blacklist" ]] && { manual_name="BLACKLIST"; online_name="ONLINE_BLACKLIST"; enabled="$BLACK_ONLINE_ENABLED"; } \
                                  || { manual_name="WHITELIST"; online_name="ONLINE_WHITELIST"; enabled="$WHITE_ONLINE_ENABLED"; }
    local -n manual="$manual_name" online="$online_name" out="$out_name"
    out=()
    for x in "${manual[@]}"; do array_has_exact "$out_name" "$x" || out+=("$x"); done
    if [[ "$enabled" == "1" ]]; then
        for x in "${online[@]}"; do array_has_exact "$out_name" "$x" || out+=("$x"); done
    fi
    sort_array "$out_name"
}

online_effective_contains_ip() {
    local kind="$1" ip="$2" tmp_name="_FWMGR_EFFECTIVE_TMP"
    local -a _FWMGR_EFFECTIVE_TMP=()
    build_effective_list "$kind" "$tmp_name"
    array_contains_ip "$tmp_name" "$ip"
}

download_online_url() {
    local url="$1" dest="$2"
    python3 - "$url" "$dest" "$ONLINE_MAX_BYTES" "$VERSION" <<'PYDL'
import sys, urllib.request, urllib.parse, urllib.error
url,dest,max_bytes,version=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme.lower() not in ('http','https'):
            raise urllib.error.URLError('redirect to unsupported scheme')
        return super().redirect_request(req, fp, code, msg, headers, newurl)
try:
    parts=urllib.parse.urlsplit(url)
    if parts.scheme.lower() not in ('http','https') or not parts.hostname:
        raise ValueError('invalid URL')
    opener=urllib.request.build_opener(SafeRedirect())
    req=urllib.request.Request(url, headers={'User-Agent':f'FWMgr/{version}'})
    with opener.open(req, timeout=30) as r, open(dest,'wb') as out:
        cl=r.headers.get('Content-Length')
        if cl and int(cl) > max_bytes:
            raise ValueError('remote file is too large')
        total=0
        while True:
            chunk=r.read(65536)
            if not chunk: break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError('remote file is too large')
            out.write(chunk)
except Exception as e:
    print(f'{type(e).__name__}: {e}', file=sys.stderr)
    raise SystemExit(1)
PYDL
}

parse_online_download() {
    local src="$1" dest="$2"
    python3 - "$src" "$dest" "$ONLINE_MAX_ENTRIES" <<'PYPARSE'
import ipaddress,re,sys
src,dest,limit=sys.argv[1],sys.argv[2],int(sys.argv[3])
text=open(src,'r',encoding='utf-8-sig',errors='replace').read()
raw=[]
for line in text.splitlines():
    line=line.split('#',1)[0]
    raw.extend(x for x in re.split(r'[\s,;]+',line.strip()) if x)
out=[]; seen=set(); invalid=0
for token in raw:
    vals=[]
    try:
        if '-' in token and '/' not in token:
            a,b=token.split('-',1)
            ia,ib=ipaddress.ip_address(a.strip()),ipaddress.ip_address(b.strip())
            if ia.version != ib.version or int(ia) > int(ib): raise ValueError
            vals=[n.with_prefixlen if n.prefixlen != n.max_prefixlen else n.network_address.compressed
                  for n in ipaddress.summarize_address_range(ia,ib)]
        elif '/' in token:
            n=ipaddress.ip_network(token,strict=False)
            vals=[n.network_address.compressed if n.prefixlen==n.max_prefixlen else n.with_prefixlen]
        else:
            vals=[ipaddress.ip_address(token).compressed]
    except ValueError:
        invalid += 1
        continue
    for v in vals:
        if v not in seen:
            seen.add(v); out.append(v)
            if len(out) > limit: raise SystemExit(f'list exceeds limit of {limit} normalized entries')
if raw and not out:
    raise SystemExit('downloaded data contains no valid IP/CIDR/range entries')
def key(s):
    n=ipaddress.ip_network(s,strict=False) if '/' in s else ipaddress.ip_network(s+('/32' if ':' not in s else '/128'),strict=False)
    return (n.version,int(n.network_address),n.prefixlen)
out.sort(key=key)
open(dest,'w',encoding='utf-8').write(('\n'.join(out)+'\n') if out else '')
print(f'{len(out)} {invalid}')
PYPARSE
}

refresh_online_kind() {
    local kind="$1" quiet="${2:-0}" urls_name dir url h raw parsed stats valid invalid
    [[ "$kind" == "blacklist" ]] && urls_name="BLACK_URLS" || urls_name="WHITE_URLS"
    local -n urls="$urls_name"
    dir="$(online_cache_dir "$kind")"
    mkdir -p "$dir"; chmod 700 "$ONLINE_ROOT" "$dir" 2>/dev/null || true
    local success=0 failed=0 retained=0
    for url in "${urls[@]}"; do
        h="$(url_hash "$url")"
        raw="$TMP_DIR/online-${kind}-${h}.raw"
        parsed="$TMP_DIR/online-${kind}-${h}.list"
        if download_online_url "$url" "$raw" 2>"$TMP_DIR/online-${h}.err" && stats="$(parse_online_download "$raw" "$parsed" 2>>"$TMP_DIR/online-${h}.err")"; then
            read -r valid invalid <<< "$stats"
            install -m 600 "$parsed" "$dir/${h}.list"
            {
                printf 'URL=%s\n' "$url"
                printf 'UPDATED=%s\n' "$(date -Is)"
                printf 'COUNT=%s\n' "${valid:-0}"
                printf 'INVALID=%s\n' "${invalid:-0}"
            } > "$dir/${h}.meta"
            chmod 600 "$dir/${h}.meta"
            success=$((success+1))
            if [[ "$quiet" != "1" ]]; then ok "Обновлен источник: $url (${valid:-0} записей, пропущено некорректных: ${invalid:-0})"; fi
        else
            failed=$((failed+1))
            [[ -f "$dir/${h}.list" ]] && retained=$((retained+1))
            if [[ "$quiet" != "1" ]]; then
                err "Не удалось обновить: $url"
                [[ -s "$TMP_DIR/online-${h}.err" ]] && sed -n '1,3p' "$TMP_DIR/online-${h}.err" >&2
                [[ -f "$dir/${h}.list" ]] && warn "Сохранен предыдущий кэш этого источника."
            fi
        fi
    done
    load_online_cache "$kind"
    [[ "$quiet" == "1" ]] || msg "Источники: успешно $success; ошибок $failed; старый кэш сохранен для $retained."
    (( failed == 0 ))
}

prune_online_cache() {
    local kind="$1" urls_name dir f base keep url h
    [[ "$kind" == "blacklist" ]] && urls_name="BLACK_URLS" || urls_name="WHITE_URLS"
    local -n urls="$urls_name"
    dir="$(online_cache_dir "$kind")"
    [[ -d "$dir" ]] || return 0
    shopt -s nullglob
    for f in "$dir"/*.list "$dir"/*.meta; do
        base="$(basename "$f")"; base="${base%.*}"; keep=0
        for url in "${urls[@]}"; do h="$(url_hash "$url")"; [[ "$h" == "$base" ]] && { keep=1; break; }; done
        (( keep )) || rm -f -- "$f"
    done
    shopt -u nullglob
}

load_state() {
    local k v
    MODE="off" ACTION="drop" BACKEND="" UFW_ENABLED_BY_FWMGR="0"
    BLACK_ONLINE_ENABLED="0" WHITE_ONLINE_ENABLED="0"
    BLACK_UPDATE_MINUTES="1440" WHITE_UPDATE_MINUTES="1440"
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r k v || [[ -n "$k" ]]; do
            case "$k" in
                MODE) [[ "$v" =~ ^(off|blacklist|whitelist)$ ]] && MODE="$v" ;;
                ACTION) [[ "$v" =~ ^(drop|reject)$ ]] && ACTION="$v" ;;
                BACKEND) [[ "$v" =~ ^(ufw|nftables)$ ]] && BACKEND="$v" ;;
                UFW_ENABLED_BY_FWMGR) [[ "$v" =~ ^[01]$ ]] && UFW_ENABLED_BY_FWMGR="$v" ;;
                BLACK_ONLINE_ENABLED) [[ "$v" =~ ^[01]$ ]] && BLACK_ONLINE_ENABLED="$v" ;;
                WHITE_ONLINE_ENABLED) [[ "$v" =~ ^[01]$ ]] && WHITE_ONLINE_ENABLED="$v" ;;
                BLACK_UPDATE_MINUTES) [[ "$v" =~ ^[1-9][0-9]*$ ]] && BLACK_UPDATE_MINUTES="$v" ;;
                WHITE_UPDATE_MINUTES) [[ "$v" =~ ^[1-9][0-9]*$ ]] && WHITE_UPDATE_MINUTES="$v" ;;
            esac
        done < "$CONFIG_FILE"
    fi
    load_list_file "$BLACKLIST_FILE" BLACKLIST
    load_list_file "$WHITELIST_FILE" WHITELIST
    load_url_file "$BLACK_URLS_FILE" BLACK_URLS
    load_url_file "$WHITE_URLS_FILE" WHITE_URLS
    load_online_cache blacklist
    load_online_cache whitelist
    SAVED_MODE="$MODE"; SAVED_ACTION="$ACTION"; SAVED_BACKEND="$BACKEND"
    SAVED_UFW_ENABLED_BY_FWMGR="$UFW_ENABLED_BY_FWMGR"
    SAVED_BLACKLIST=("${BLACKLIST[@]}")
    SAVED_WHITELIST=("${WHITELIST[@]}")
    SAVED_BLACK_URLS=("${BLACK_URLS[@]}")
    SAVED_WHITE_URLS=("${WHITE_URLS[@]}")
    SAVED_BLACK_ONLINE_ENABLED="$BLACK_ONLINE_ENABLED"
    SAVED_WHITE_ONLINE_ENABLED="$WHITE_ONLINE_ENABLED"
    SAVED_BLACK_UPDATE_MINUTES="$BLACK_UPDATE_MINUTES"
    SAVED_WHITE_UPDATE_MINUTES="$WHITE_UPDATE_MINUTES"
    DIRTY=0
}

write_state_files() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    local cf="$TMP_DIR/config.new" bf="$TMP_DIR/blacklist.new" wf="$TMP_DIR/whitelist.new" buf="$TMP_DIR/blacklist_urls.new" wuf="$TMP_DIR/whitelist_urls.new"
    cat > "$cf" <<CFG
VERSION=${VERSION}
FORMAT_VERSION=${FORMAT_VERSION}
MODE=${MODE}
ACTION=${ACTION}
BACKEND=${BACKEND}
UFW_ENABLED_BY_FWMGR=${UFW_ENABLED_BY_FWMGR}
BLACK_ONLINE_ENABLED=${BLACK_ONLINE_ENABLED}
WHITE_ONLINE_ENABLED=${WHITE_ONLINE_ENABLED}
BLACK_UPDATE_MINUTES=${BLACK_UPDATE_MINUTES}
WHITE_UPDATE_MINUTES=${WHITE_UPDATE_MINUTES}
CFG
    : > "$bf"; : > "$wf"; : > "$buf"; : > "$wuf"
    sort_array BLACKLIST; sort_array WHITELIST
    ((${#BLACKLIST[@]})) && printf '%s\n' "${BLACKLIST[@]}" > "$bf"
    ((${#WHITELIST[@]})) && printf '%s\n' "${WHITELIST[@]}" > "$wf"
    ((${#BLACK_URLS[@]})) && printf '%s\n' "${BLACK_URLS[@]}" > "$buf"
    ((${#WHITE_URLS[@]})) && printf '%s\n' "${WHITE_URLS[@]}" > "$wuf"
    install -m 600 "$cf" "$CONFIG_FILE"
    install -m 600 "$bf" "$BLACKLIST_FILE"
    install -m 600 "$wf" "$WHITELIST_FILE"
    install -m 600 "$buf" "$BLACK_URLS_FILE"
    install -m 600 "$wuf" "$WHITE_URLS_FILE"
}

mark_saved() {
    SAVED_MODE="$MODE"; SAVED_ACTION="$ACTION"; SAVED_BACKEND="$BACKEND"
    SAVED_UFW_ENABLED_BY_FWMGR="$UFW_ENABLED_BY_FWMGR"
    SAVED_BLACKLIST=("${BLACKLIST[@]}")
    SAVED_WHITELIST=("${WHITELIST[@]}")
    SAVED_BLACK_URLS=("${BLACK_URLS[@]}")
    SAVED_WHITE_URLS=("${WHITE_URLS[@]}")
    SAVED_BLACK_ONLINE_ENABLED="$BLACK_ONLINE_ENABLED"
    SAVED_WHITE_ONLINE_ENABLED="$WHITE_ONLINE_ENABLED"
    SAVED_BLACK_UPDATE_MINUTES="$BLACK_UPDATE_MINUTES"
    SAVED_WHITE_UPDATE_MINUTES="$WHITE_UPDATE_MINUTES"
    DIRTY=0
}

detect_firewalls() {
    UFW_INSTALLED=0; NFT_INSTALLED=0; UFW_ACTIVE=0; NFT_SERVICE_ACTIVE=0
    FIREWALLD_ACTIVE=0; NETFILTER_PERSISTENT_ACTIVE=0; DOCKER_ACTIVE=0; FAIL2BAN_ACTIVE=0
    HAS_CONFLICT=0; CONFLICT_TEXT=""; RESOLVED_BACKEND=""

    pkg_installed ufw && UFW_INSTALLED=1
    pkg_installed nftables && NFT_INSTALLED=1
    if (( UFW_INSTALLED )) && ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'; then UFW_ACTIVE=1; fi
    service_active nftables.service && NFT_SERVICE_ACTIVE=1
    service_active firewalld.service && FIREWALLD_ACTIVE=1
    service_active netfilter-persistent.service && NETFILTER_PERSISTENT_ACTIVE=1
    service_active docker.service && DOCKER_ACTIVE=1
    service_active fail2ban.service && FAIL2BAN_ACTIVE=1

    local reasons=()
    if (( UFW_ACTIVE && NFT_SERVICE_ACTIVE )); then reasons+=("UFW и nftables.service активны одновременно"); fi
    if (( FIREWALLD_ACTIVE )); then reasons+=("активен firewalld (не поддерживается FWMgr)"); fi
    if (( NETFILTER_PERSISTENT_ACTIVE )); then reasons+=("активен netfilter-persistent/iptables-persistent (не поддерживается FWMgr)"); fi
    if ((${#reasons[@]})); then
        HAS_CONFLICT=1
        CONFLICT_TEXT="$(IFS='; '; echo "${reasons[*]}")"
    fi

    if (( UFW_ACTIVE && !NFT_SERVICE_ACTIVE )); then
        RESOLVED_BACKEND="ufw"
    elif (( NFT_SERVICE_ACTIVE && !UFW_ACTIVE )); then
        RESOLVED_BACKEND="nftables"
    elif [[ "$BACKEND" == "ufw" ]] && (( UFW_INSTALLED )); then
        RESOLVED_BACKEND="ufw"
    elif [[ "$BACKEND" == "nftables" ]] && (( NFT_INSTALLED )); then
        RESOLVED_BACKEND="nftables"
    elif (( UFW_INSTALLED && !NFT_INSTALLED )); then
        RESOLVED_BACKEND="ufw"
    elif (( NFT_INSTALLED && !UFW_INSTALLED )); then
        RESOLVED_BACKEND="nftables"
    fi
}

firewall_available() {
    detect_firewalls
    (( HAS_CONFLICT == 0 )) && (( UFW_INSTALLED || NFT_INSTALLED ))
}

ensure_backend() {
    detect_firewalls
    if (( HAS_CONFLICT )); then
        err "Невозможно продолжить: $CONFLICT_TEXT"
        return 1
    fi
    if [[ -n "$RESOLVED_BACKEND" ]]; then
        if [[ "$BACKEND" != "$RESOLVED_BACKEND" ]]; then BACKEND="$RESOLVED_BACKEND"; DIRTY=1; fi
        return 0
    fi
    if (( UFW_INSTALLED && NFT_INSTALLED )); then
        clear_screen
        msg "$APP_TITLE"
        msg "Оба поддерживаемых firewall установлены, но активный backend не определён."
        msg "1. UFW"
        msg "2. nftables"
        msg "0. Отмена"
        local c
        read -r -p "> " c || return 1
        case "$c" in
            1) BACKEND="ufw"; DIRTY=1; return 0 ;;
            2) BACKEND="nftables"; DIRTY=1; return 0 ;;
            *) return 1 ;;
        esac
    fi
    err "Поддерживаемый firewall не установлен."
    return 1
}

mode_ru() {
    case "$MODE" in off) echo "выключен";; blacklist) echo "черный";; whitelist) echo "белый";; esac
}
action_ru() { [[ "$ACTION" == "drop" ]] && echo "DROP" || echo "REJECT"; }

print_firewall_status() {
    detect_firewalls
    if (( HAS_CONFLICT )); then
        printf 'Firewall: %bКОНФЛИКТ%b (%s)\n' "$C_RED" "$C_RESET" "$CONFLICT_TEXT"
        return
    fi
    if (( !UFW_INSTALLED && !NFT_INSTALLED )); then
        printf 'Firewall: %bотсутствует%b\n' "$C_RED" "$C_RESET"
        return
    fi
    local parts=()
    (( UFW_INSTALLED )) && parts+=("UFW:$([[ $UFW_ACTIVE -eq 1 ]] && echo активен || echo неактивен)")
    (( NFT_INSTALLED )) && parts+=("nftables:$([[ $NFT_SERVICE_ACTIVE -eq 1 ]] && echo сервис-активен || echo сервис-неактивен)")
    printf 'Firewall: %bустановлен%b (%s)\n' "$C_GREEN" "$C_RESET" "$(IFS=', '; echo "${parts[*]}")"
    if [[ -n "$RESOLVED_BACKEND" ]]; then
        printf 'Backend FWMgr: %s\n' "$RESOLVED_BACKEND"
    else
        printf 'Backend FWMgr: %bне выбран%b\n' "$C_YELLOW" "$C_RESET"
    fi
}

print_other_managers() {
    local x=()
    (( DOCKER_ACTIVE )) && x+=("Docker")
    (( FAIL2BAN_ACTIVE )) && x+=("Fail2ban")
    if ((${#x[@]})); then gray "Другие владельцы Netfilter: $(IFS=', '; echo "${x[*]}") (не считаются конфликтом)"; fi
}

show_main_menu() {
    clear_screen
    print_title
    print_firewall_status
    printf 'Режим списков: %s\n' "$(mode_ru)"
    printf 'Отклонение соединений: %s\n' "$(action_ru)"
    if [[ "$BLACK_ONLINE_ENABLED" == "1" ]]; then printf 'Кол-во IP/подсетей в черном списке: %d вручную + %d онлайн\n' "${#BLACKLIST[@]}" "${#ONLINE_BLACKLIST[@]}"; else printf 'Кол-во IP/подсетей в черном списке: %d\n' "${#BLACKLIST[@]}"; fi
    if [[ "$WHITE_ONLINE_ENABLED" == "1" ]]; then printf 'Кол-во IP/подсетей в белом списке: %d вручную + %d онлайн\n' "${#WHITELIST[@]}" "${#ONLINE_WHITELIST[@]}"; else printf 'Кол-во IP/подсетей в белом списке: %d\n' "${#WHITELIST[@]}"; fi
    printf 'Ваш IP адрес: %s\n' "${CURRENT_IP:-не определен}"
    print_other_managers
    (( DIRTY )) && printf '%bЕсть несохраненные изменения%b\n' "$C_YELLOW" "$C_RESET"
    printf '\n'

    if firewall_available; then
        msg "1. Переключить режим (выкл/черный/белый)"
        msg "2. Отклонение соединений (DROP/REJECT)"
        msg "3. Черный список"
        msg "4. Белый список"
        msg "5. Экспорт/импорт настроек"
        msg "6. Сохранить"
    else
        gray "1. Переключить режим (недоступно)"
        gray "2. Отклонение соединений (недоступно)"
        gray "3. Черный список (недоступно)"
        gray "4. Белый список (недоступно)"
        gray "5. Экспорт/импорт настроек (недоступно)"
        gray "6. Сохранить (недоступно)"
    fi
    msg "7. Удалить FWMgr"
    if (( UPDATE_AVAILABLE )); then
        printf '8. Обновить FWMgr: v%s -> v%s\n' "$VERSION" "$LATEST_VERSION"
    else
        msg "8. Проверить обновления FWMgr"
    fi
    if (( UFW_INSTALLED || NFT_INSTALLED )); then gray "9. Установить Firewall (уже установлен поддерживаемый пакет)"; else msg "9. Установить Firewall"; fi
    msg "0. Выход"
}

print_external_ufw_rules() {
    if ! command -v ufw >/dev/null 2>&1; then return; fi
    local out
    out="$(ufw status numbered 2>/dev/null || true)"
    local found=0 line
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[[:space:]]*[0-9]+\] ]]; then
            gray "  $line"
            found=1
        fi
    done <<< "$out"
    (( found )) || gray "  (обычных пользовательских UFW-правил нет)"
}

print_external_nft_rules() {
    command -v nft >/dev/null 2>&1 || return
    local raw="$TMP_DIR/nft.rules"
    nft -a list ruleset > "$raw" 2>/dev/null || { gray "  (не удалось прочитать ruleset)"; return; }
    python3 - "$raw" "$NFT_TABLE_NAME" <<'PY' | while IFS= read -r line; do gray "  $line"; done
import re,sys
text=open(sys.argv[1],encoding='utf-8',errors='replace').read().splitlines()
exclude=sys.argv[2]
res=[]
i=0
cur_table=None
while i < len(text):
    line=text[i]
    m=re.match(r'\s*table\s+(\S+)\s+(\S+)\s*\{', line)
    if m:
        fam,name=m.groups(); cur_table=(fam,name)
    cm=re.match(r'\s*chain\s+(\S+)\s*\{', line)
    if cm and cur_table and cur_table[1] != exclude:
        start=i; depth=line.count('{')-line.count('}'); i+=1
        while i < len(text) and depth>0:
            depth += text[i].count('{')-text[i].count('}')
            i+=1
        block=text[start:i]
        if any(re.search(r'\bhook\s+input\b', x) for x in block):
            res.append(f"{cur_table[0]} {cur_table[1]} / chain {cm.group(1)}")
            for x in block[1:-1]:
                s=x.strip()
                if s and not s.startswith('type filter hook input'):
                    res.append('  '+s)
        continue
    i+=1
if not res: print('(внешних base-chain правил с hook input не найдено)')
else:
    for x in res: print(x)
PY
}

print_external_rules() {
    detect_firewalls
    msg "Внешние правила входящего трафика (только чтение):"
    case "${RESOLVED_BACKEND:-$BACKEND}" in
        ufw) print_external_ufw_rules ;;
        nftables) print_external_nft_rules ;;
        *) gray "  (backend не выбран)" ;;
    esac
    msg ""
}

show_managed_list() {
    local arr_name="$1"
    local -n arr="$arr_name"
    sort_array "$arr_name"
    if ((${#arr[@]} == 0)); then
        gray "  (список FWMgr пуст)"
    else
        local i
        for ((i=0;i<${#arr[@]};i++)); do printf '  %d. %s\n' "$((i+1))" "${arr[i]}"; done
    fi
}

read_entries_multiline() {
    local arr_name="$1" line token norm
    local -n arr="$arr_name"
    msg "Введите IP-адреса/подсети. Разделители: пробел, запятая или новая строка."
    msg "Пустая строка завершает ввод."
    local added=0 skipped=0 invalid=0
    while true; do
        IFS= read -r line || break
        [[ -z "$line" ]] && break
        line="${line//,/ }"
        local tokens=()
        read -r -a tokens <<< "$line"
        for token in "${tokens[@]}"; do
            [[ -n "$token" ]] || continue
            if ! norm="$(normalize_entry "$token" 2>/dev/null)"; then
                err "Некорректный адрес/подсеть: $token"
                invalid=$((invalid+1)); continue
            fi
            if array_has_exact "$arr_name" "$norm"; then
                skipped=$((skipped+1)); continue
            fi
            arr+=("$norm"); added=$((added+1))
        done
    done
    sort_array "$arr_name"
    if (( added > 0 )); then DIRTY=1; fi
    msg "Добавлено: $added; дубликатов пропущено: $skipped; некорректных: $invalid"
}

delete_by_numbers() {
    local arr_name="$1" input n
    local -n arr="$arr_name"
    ((${#arr[@]})) || { warn "Список пуст."; return; }
    read -r -p "Введите номера для удаления (через пробел или запятую): " input || return
    input="${input//,/ }"
    local nums=() seen=" "
    for n in $input; do
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "Пропущено: $n"; continue; }
        (( n >= 1 && n <= ${#arr[@]} )) || { warn "Номер вне диапазона: $n"; continue; }
        [[ "$seen" == *" $n "* ]] && continue
        seen+="$n "
        nums+=("$n")
    done
    ((${#nums[@]})) || return
    mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -nr)
    for n in "${nums[@]}"; do unset 'arr[n-1]'; done
    arr=("${arr[@]}")
    sort_array "$arr_name"
    DIRTY=1
    ok "Удалено: ${#nums[@]}"
}

clear_managed_list() {
    local arr_name="$1" is_white="${2:-0}"
    local -n arr="$arr_name"
    confirm "Очистить список?" || return
    arr=()
    if [[ "$is_white" == "1" && -n "$CURRENT_IP" ]]; then
        arr+=("$CURRENT_IP")
        warn "Белый список очищен. Текущий SSH IP автоматически добавлен: $CURRENT_IP"
    else
        ok "Список очищен."
    fi
    DIRTY=1
}

online_enabled_ru() {
    [[ "$1" == "1" ]] && echo "включена" || echo "отключена"
}

read_urls_multiline() {
    local arr_name="$1" line url
    local -n arr="$arr_name"
    msg "Введите HTTP/HTTPS ссылки на сырые текстовые списки, по одной на строку."
    msg "Пустая строка завершает ввод."
    local added=0 skipped=0 invalid=0
    while true; do
        IFS= read -r line || break
        [[ -z "$line" ]] && break
        line="${line//$'\r'/}"
        url="${line#${line%%[![:space:]]*}}"; url="${url%${url##*[![:space:]]}}"
        [[ -n "$url" ]] || continue
        if ! validate_online_url "$url"; then
            err "Некорректный URL (разрешены только http/https без логина/пароля): $url"
            invalid=$((invalid+1)); continue
        fi
        if array_has_exact "$arr_name" "$url"; then skipped=$((skipped+1)); continue; fi
        arr+=("$url"); added=$((added+1))
    done
    (( added > 0 )) && DIRTY=1
    msg "Добавлено: $added; дубликатов пропущено: $skipped; некорректных: $invalid"
}

delete_urls_by_numbers() {
    local arr_name="$1" input n
    local -n arr="$arr_name"
    ((${#arr[@]})) || { warn "Список источников пуст."; return; }
    read -r -p "Введите номера URL для удаления (через пробел или запятую): " input || return
    input="${input//,/ }"
    local nums=() seen=" "
    for n in $input; do
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "Пропущено: $n"; continue; }
        (( n >= 1 && n <= ${#arr[@]} )) || { warn "Номер вне диапазона: $n"; continue; }
        [[ "$seen" == *" $n "* ]] && continue
        seen+="$n "; nums+=("$n")
    done
    ((${#nums[@]})) || return
    mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -nr)
    for n in "${nums[@]}"; do unset 'arr[n-1]'; done
    arr=("${arr[@]}")
    DIRTY=1
    ok "Удалено URL: ${#nums[@]}"
}

show_online_sources() {
    local kind="$1" urls_name dir url h meta updated count invalid i
    [[ "$kind" == "blacklist" ]] && urls_name="BLACK_URLS" || urls_name="WHITE_URLS"
    local -n urls="$urls_name"
    dir="$(online_cache_dir "$kind")"
    if ((${#urls[@]} == 0)); then gray "  (источники не добавлены)"; return; fi
    for ((i=0;i<${#urls[@]};i++)); do
        url="${urls[i]}"; h="$(url_hash "$url")"; meta="$dir/${h}.meta"
        updated="не обновлялся"; count="0"; invalid="0"
        if [[ -f "$meta" ]]; then
            updated="$(grep -m1 '^UPDATED=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
            count="$(grep -m1 '^COUNT=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
            invalid="$(grep -m1 '^INVALID=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
            [[ -n "$updated" ]] || updated="неизвестно"; [[ -n "$count" ]] || count="0"; [[ -n "$invalid" ]] || invalid="0"
        fi
        printf '  %d. %s\n' "$((i+1))" "$url"
        gray "     кэш: ${count} записей; обновление: ${updated}; некорректных при загрузке: ${invalid}"
    done
}

online_sources_menu() {
    local kind="$1" urls_name title
    if [[ "$kind" == "blacklist" ]]; then urls_name="BLACK_URLS"; title="Онлайн-списки: черный список"; else urls_name="WHITE_URLS"; title="Онлайн-списки: белый список"; fi
    while true; do
        clear_screen
        printf '%b%s%b\n\n' "$C_BOLD" "$title" "$C_RESET"
        show_online_sources "$kind"
        msg ""
        msg "1. Добавить URL"
        msg "2. Удалить URL"
        msg "3. Очистить список URL"
        msg "4. Обновить кэш сейчас (применить после сохранения)"
        msg "0. Назад"
        local c
        read -r -p "> " c || return
        case "$c" in
            1) read_urls_multiline "$urls_name"; load_online_cache "$kind"; pause_screen ;;
            2) delete_urls_by_numbers "$urls_name"; load_online_cache "$kind"; pause_screen ;;
            3) if confirm "Удалить все URL этого онлайн-списка?"; then local -n _urls="$urls_name"; _urls=(); load_online_cache "$kind"; DIRTY=1; ok "URL очищены. Изменение вступит в силу после сохранения."; fi; pause_screen ;;
            4) refresh_online_kind "$kind" 0 || true; warn "Кэш обновлен. Живые правила firewall изменятся только после «Сохранить»."; pause_screen ;;
            0) return ;;
        esac
    done
}

set_online_interval() {
    local kind="$1" value current
    [[ "$kind" == "blacklist" ]] && current="$BLACK_UPDATE_MINUTES" || current="$WHITE_UPDATE_MINUTES"
    read -r -p "Интервал обновления в минутах [${current}]: " value || return
    [[ -n "$value" ]] || return
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then err "Введите целое число минут больше нуля."; return 1; fi
    if (( value > 5256000 )); then err "Слишком большой интервал."; return 1; fi
    if [[ "$kind" == "blacklist" ]]; then BLACK_UPDATE_MINUTES="$value"; else WHITE_UPDATE_MINUTES="$value"; fi
    DIRTY=1
}

toggle_online_kind() {
    local kind="$1"
    if [[ "$kind" == "blacklist" ]]; then
        [[ "$BLACK_ONLINE_ENABLED" == "1" ]] && BLACK_ONLINE_ENABLED="0" || BLACK_ONLINE_ENABLED="1"
    else
        [[ "$WHITE_ONLINE_ENABLED" == "1" ]] && WHITE_ONLINE_ENABLED="0" || WHITE_ONLINE_ENABLED="1"
    fi
    DIRTY=1
}

list_menu() {
    local kind="$1" arr_name title is_white=0 online_enabled interval online_count label
    if [[ "$kind" == "black" ]]; then
        arr_name="BLACKLIST"; title="Черный список"; online_enabled="$BLACK_ONLINE_ENABLED"; interval="$BLACK_UPDATE_MINUTES"; online_count="${#ONLINE_BLACKLIST[@]}"; label="Блокировка адресов из онлайн-списков"
    else
        arr_name="WHITELIST"; title="Белый список"; is_white=1; online_enabled="$WHITE_ONLINE_ENABLED"; interval="$WHITE_UPDATE_MINUTES"; online_count="${#ONLINE_WHITELIST[@]}"; label="Разрешение адресов из онлайн-списков"
    fi
    while true; do
        if [[ "$kind" == "black" ]]; then online_enabled="$BLACK_ONLINE_ENABLED"; interval="$BLACK_UPDATE_MINUTES"; online_count="${#ONLINE_BLACKLIST[@]}"; else online_enabled="$WHITE_ONLINE_ENABLED"; interval="$WHITE_UPDATE_MINUTES"; online_count="${#ONLINE_WHITELIST[@]}"; fi
        clear_screen
        printf '%b%s%b\n\n' "$C_BOLD" "$title" "$C_RESET"
        if (( is_white )) && [[ -n "$CURRENT_IP" ]] && ! online_effective_contains_ip whitelist "$CURRENT_IP"; then
            printf '%b%s%b\n\n' "$C_RED$C_BOLD" "ВНИМАНИЕ! ВАШ IP АДРЕС ОТСУТСТВУЕТ В СПИСКЕ. ПОСЛЕ СОХРАНЕНИЯ НАСТРОЕК ВЫ ПОТЕРЯЕТЕ ДОСТУП К СЕРВЕРУ" "$C_RESET"
        fi
        print_external_rules
        msg "Правила FWMgr, добавленные вручную:"
        show_managed_list "$arr_name"
        if [[ "$online_enabled" == "1" ]]; then gray "  Онлайн-кэш (только чтение): ${online_count} IP/подсетей"; fi
        if [[ "$kind" == "black" ]]; then gray "  Белый список имеет приоритет как исключение из черного списка."; fi
        msg ""
        msg "1. Добавить IP адреса / подсети"
        msg "2. Удалить IP адреса / подсети"
        msg "3. Очистить"
        msg "4. ${label}: $(online_enabled_ru "$online_enabled")"
        msg "5. Обновление списков: ${interval} минут"
        msg "6. Менеджер онлайн-списков"
        msg "0. Назад"
        local c
        read -r -p "> " c || return
        case "$c" in
            1) read_entries_multiline "$arr_name"; pause_screen ;;
            2) delete_by_numbers "$arr_name"; pause_screen ;;
            3) clear_managed_list "$arr_name" "$is_white"; pause_screen ;;
            4) toggle_online_kind "$([[ "$kind" == "black" ]] && echo blacklist || echo whitelist)" ;;
            5) set_online_interval "$([[ "$kind" == "black" ]] && echo blacklist || echo whitelist)"; pause_screen ;;
            6) online_sources_menu "$([[ "$kind" == "black" ]] && echo blacklist || echo whitelist)" ;;
            0) return ;;
        esac
    done
}

cycle_mode() {
    case "$MODE" in off) MODE="blacklist";; blacklist) MODE="whitelist";; whitelist) MODE="off";; esac
    DIRTY=1
}

toggle_action() {
    [[ "$ACTION" == "drop" ]] && ACTION="reject" || ACTION="drop"
    DIRTY=1
}

protect_ssh_ip_before_save() {
    [[ -n "$CURRENT_IP" ]] || {
        if [[ "$MODE" == "whitelist" ]]; then
            printf '%b%s%b\n' "$C_RED$C_BOLD" "ВНИМАНИЕ: текущий SSH IP определить не удалось. Автоматическая защита от потери доступа невозможна." "$C_RESET"
            confirm "Продолжить сохранение белого режима?" || return 1
        fi
        return 0
    }

    local removed
    REMOVE_ENTRIES_COUNT=0
    remove_entries_containing_ip BLACKLIST "$CURRENT_IP"
    removed="$REMOVE_ENTRIES_COUNT"
    if (( removed > 0 )); then
        warn "Из черного списка удалено правил, перекрывавших ваш SSH IP ($CURRENT_IP): $removed"
        DIRTY=1
    fi
    if ! array_contains_ip WHITELIST "$CURRENT_IP"; then
        WHITELIST+=("$CURRENT_IP")
        sort_array WHITELIST
        warn "Ваш SSH IP автоматически добавлен в белый список: $CURRENT_IP"
        DIRTY=1
    fi
    if [[ "$MODE" == "blacklist" && "$BLACK_ONLINE_ENABLED" == "1" ]] && array_contains_ip ONLINE_BLACKLIST "$CURRENT_IP"; then
        warn "Ваш SSH IP присутствует в онлайн-blacklist, но защищен приоритетным правилом белого списка."
    fi
    return 0
}

make_backup_dir() {
    local ts dir
    ts="$(date '+%Y%m%d_%H%M%S')"
    dir="${BACKUP_ROOT}/${ts}_$$"
    mkdir -p "$dir"
    chmod 700 "$BACKUP_ROOT" "$dir" 2>/dev/null || true
    printf '%s' "$dir"
}

backup_fwmgr_state() {
    local dir="$1"
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$dir/config" || true
    [[ -f "$BLACKLIST_FILE" ]] && cp -a "$BLACKLIST_FILE" "$dir/blacklist" || true
    [[ -f "$WHITELIST_FILE" ]] && cp -a "$WHITELIST_FILE" "$dir/whitelist" || true
    [[ -f "$BLACK_URLS_FILE" ]] && cp -a "$BLACK_URLS_FILE" "$dir/blacklist_urls" || true
    [[ -f "$WHITE_URLS_FILE" ]] && cp -a "$WHITE_URLS_FILE" "$dir/whitelist_urls" || true
    [[ -f "$NFT_FILE" ]] && cp -a "$NFT_FILE" "$dir/fwmgr.nft" || true
}

strip_and_patch_ufw_file() {
    local file="$1" family="$2" rules_file="$3" mode="$4"
    python3 - "$file" "$family" "$rules_file" "$mode" "$UFW_CHAIN" <<'PY'
import sys,re
path,family,rules_path,mode,chain=sys.argv[1:]
text=open(path,encoding='utf-8').read().splitlines()
markers=[('CHAIN',f'# BEGIN FWMGR CHAIN',f'# END FWMGR CHAIN'),('RULES',f'# BEGIN FWMGR RULES',f'# END FWMGR RULES')]
for _,beg,end in markers:
    out=[]; inside=False
    for line in text:
        stripped=line.strip()
        if stripped==beg:
            if inside: raise SystemExit(f'Повреждены маркеры FWMgr в {path}: повторный {beg}')
            inside=True; continue
        if stripped==end:
            if not inside: raise SystemExit(f'Повреждены маркеры FWMgr в {path}: {end} без начала')
            inside=False; continue
        if not inside: out.append(line)
    if inside: raise SystemExit(f'Повреждены маркеры FWMgr в {path}: отсутствует {end}')
    text=out
# Refuse to touch a same-named chain not owned by our marker.
for line in text:
    if re.search(rf'(^|\s)[:\-j ]{re.escape(chain)}(?:\s|$)', line) and (line.strip().startswith(':'+chain) or ('-j '+chain) in line or ('-A '+chain) in line):
        raise SystemExit(f'Обнаружена внешняя цепочка {chain} без маркеров FWMgr в {path}')
if mode=='off':
    open(path,'w',encoding='utf-8').write('\n'.join(text)+'\n')
    raise SystemExit(0)
# Locate *filter and the first ufw-before-input rule inside it.
filter_idx=None; commit_idx=None
for i,line in enumerate(text):
    if line.strip()=='*filter':
        filter_idx=i; break
if filter_idx is None: raise SystemExit(f'В {path} не найден раздел *filter')
for i in range(filter_idx+1,len(text)):
    if text[i].strip()=='COMMIT': commit_idx=i; break
if commit_idx is None: raise SystemExit(f'В {path} не найден COMMIT для *filter')
# chain declaration directly after *filter is valid and stays isolated by markers.
chain_block=['# BEGIN FWMGR CHAIN',f':{chain} - [0:0]','# END FWMGR CHAIN']
text[filter_idx+1:filter_idx+1]=chain_block
commit_idx += len(chain_block)
insert_rule=None
for i in range(filter_idx+1,commit_idx):
    if re.match(r'^\s*-A\s+ufw-before-input\b', text[i]):
        insert_rule=i; break
if insert_rule is None: raise SystemExit(f'В {path} не найдена цепочка ufw-before-input')
rules=open(rules_path,encoding='utf-8').read().splitlines()
rule_block=['# BEGIN FWMGR RULES']+rules+['# END FWMGR RULES']
text[insert_rule:insert_rule]=rule_block
open(path,'w',encoding='utf-8').write('\n'.join(text)+'\n')
PY
}

generate_ufw_rules_file() {
    local family="$1" out="$2" entry ver target
    local -a effective=()
    : > "$out"
    printf '%s\n' "-A ${UFW_CHAIN} -i lo -j RETURN" >> "$out"
    printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" >> "$out"
    if [[ "$family" == "6" ]]; then
        printf '%s\n' "-A ${UFW_CHAIN} -s fe80::/10 -p ipv6-icmp -j RETURN" >> "$out"
        for target in destination-unreachable packet-too-big time-exceeded parameter-problem; do
            printf '%s\n' "-A ${UFW_CHAIN} -p ipv6-icmp --icmpv6-type ${target} -j RETURN" >> "$out"
        done
    fi
    if [[ "$MODE" == "blacklist" ]]; then
        # Белый список имеет приоритет как исключение из blacklist, в том числе для защиты SSH от онлайн-источников.
        for entry in "${WHITELIST[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            [[ "$ver" == "$family" ]] || continue
            printf '%s\n' "-A ${UFW_CHAIN} -s ${entry} -j RETURN" >> "$out"
        done
        build_effective_list blacklist effective
        for entry in "${effective[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            [[ "$ver" == "$family" ]] || continue
            if [[ "$ACTION" == "drop" ]]; then
                printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -s ${entry} -j DROP" >> "$out"
            else
                printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -s ${entry} -j REJECT" >> "$out"
            fi
        done
    elif [[ "$MODE" == "whitelist" ]]; then
        build_effective_list whitelist effective
        for entry in "${effective[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            [[ "$ver" == "$family" ]] || continue
            printf '%s\n' "-A ${UFW_CHAIN} -s ${entry} -j RETURN" >> "$out"
        done
        if [[ "$ACTION" == "drop" ]]; then
            printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -j DROP" >> "$out"
        else
            printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -j REJECT" >> "$out"
        fi
    fi
    printf '%s\n' "-A ${UFW_CHAIN} -j RETURN" >> "$out"
}

apply_ufw() {
    (( UFW_INSTALLED )) || { err "UFW не установлен."; return 1; }
    if [[ "$MODE" != "off" ]]; then
        if [[ ! -f /etc/ufw/before6.rules ]] || ! grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes[[:space:]]*$' /etc/default/ufw 2>/dev/null; then
            err "UFW настроен без IPv6. FWMgr не применяет неполный whitelist/blacklist: включите IPV6=yes в /etc/default/ufw и повторите сохранение."
            return 1
        fi
    fi
    local bdir was_active=0
    bdir="$(make_backup_dir)"
    backup_fwmgr_state "$bdir"
    [[ -f /etc/ufw/before.rules ]] && cp -a /etc/ufw/before.rules "$bdir/before.rules"
    [[ -f /etc/ufw/before6.rules ]] && cp -a /etc/ufw/before6.rules "$bdir/before6.rules"
    (( UFW_ACTIVE )) && was_active=1
    printf '%s\n' "$was_active" > "$bdir/ufw_was_active"

    local r4="$TMP_DIR/ufw4.rules" r6="$TMP_DIR/ufw6.rules"
    generate_ufw_rules_file 4 "$r4"
    generate_ufw_rules_file 6 "$r6"

    if ! strip_and_patch_ufw_file /etc/ufw/before.rules 4 "$r4" "$MODE"; then
        err "Не удалось подготовить /etc/ufw/before.rules"
        [[ -f "$bdir/before.rules" ]] && cp -a "$bdir/before.rules" /etc/ufw/before.rules
        return 1
    fi
    if [[ -f /etc/ufw/before6.rules ]]; then
        if ! strip_and_patch_ufw_file /etc/ufw/before6.rules 6 "$r6" "$MODE"; then
            err "Не удалось подготовить /etc/ufw/before6.rules"
            [[ -f "$bdir/before.rules" ]] && cp -a "$bdir/before.rules" /etc/ufw/before.rules
            [[ -f "$bdir/before6.rules" ]] && cp -a "$bdir/before6.rules" /etc/ufw/before6.rules
            return 1
        fi
    fi

    local dry_cmd="reload"
    (( was_active )) || dry_cmd="enable"
    if ! ufw --dry-run "$dry_cmd" >/dev/null 2>"$TMP_DIR/ufw-dry.err"; then
        err "UFW отклонил подготовленную конфигурацию:"
        cat "$TMP_DIR/ufw-dry.err" >&2 || true
        [[ -f "$bdir/before.rules" ]] && cp -a "$bdir/before.rules" /etc/ufw/before.rules
        [[ -f "$bdir/before6.rules" ]] && cp -a "$bdir/before6.rules" /etc/ufw/before6.rules
        return 1
    fi

    local failed=0
    if [[ "$MODE" == "off" ]]; then
        if (( was_active )); then ufw reload >/dev/null 2>&1 || failed=1; fi
        if (( !failed )) && [[ "$UFW_ENABLED_BY_FWMGR" == "1" ]]; then
            ufw disable >/dev/null 2>&1 || failed=1
            (( !failed )) && UFW_ENABLED_BY_FWMGR="0"
        fi
    else
        if (( was_active )); then
            ufw reload >/dev/null 2>&1 || failed=1
        else
            ufw --force enable >/dev/null 2>&1 || failed=1
            (( !failed )) && UFW_ENABLED_BY_FWMGR="1"
        fi
    fi

    if (( failed )); then
        err "Ошибка применения UFW. Выполняется откат файлов."
        [[ -f "$bdir/before.rules" ]] && cp -a "$bdir/before.rules" /etc/ufw/before.rules
        [[ -f "$bdir/before6.rules" ]] && cp -a "$bdir/before6.rules" /etc/ufw/before6.rules
        if (( was_active )); then ufw --force enable >/dev/null 2>&1 || true; ufw reload >/dev/null 2>&1 || true
        else ufw disable >/dev/null 2>&1 || true
        fi
        UFW_ENABLED_BY_FWMGR="$SAVED_UFW_ENABLED_BY_FWMGR"
        return 1
    fi
    return 0
}

generate_nft_file() {
    local out="$1" entry ver verdict
    local -a effective=()
    verdict="$ACTION"
    cat > "$out" <<NFT
# Managed by FWMgr ${VERSION}. Do not edit this file by hand.
table inet ${NFT_TABLE_NAME} {
    chain input {
        type filter hook input priority 100; policy accept;
        iifname "lo" accept
        ct state established,related accept
        ip6 saddr fe80::/10 meta l4proto ipv6-icmp accept
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
NFT
    if [[ "$MODE" == "blacklist" ]]; then
        for entry in "${WHITELIST[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            if [[ "$ver" == "4" ]]; then printf '        ip saddr %s accept\n' "$entry" >> "$out"; else printf '        ip6 saddr %s accept\n' "$entry" >> "$out"; fi
        done
        build_effective_list blacklist effective
        for entry in "${effective[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            if [[ "$ver" == "4" ]]; then
                printf '        ct state new ip saddr %s %s\n' "$entry" "$verdict" >> "$out"
            else
                printf '        ct state new ip6 saddr %s %s\n' "$entry" "$verdict" >> "$out"
            fi
        done
    elif [[ "$MODE" == "whitelist" ]]; then
        build_effective_list whitelist effective
        for entry in "${effective[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            if [[ "$ver" == "4" ]]; then printf '        ip saddr %s accept\n' "$entry" >> "$out"; else printf '        ip6 saddr %s accept\n' "$entry" >> "$out"; fi
        done
        printf '        ct state new %s\n' "$verdict" >> "$out"
    fi
    cat >> "$out" <<'NFT'
    }
}
NFT
}

write_nft_systemd_unit() {
    cat > "$TMP_DIR/fwmgr-nft.service" <<'UNIT'
[Unit]
Description=FWMgr nftables input filter
Documentation=man:nft(8)
After=nftables.service
PartOf=nftables.service
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/nft list table inet fwmgr >/dev/null 2>&1 && /usr/sbin/nft delete table inet fwmgr || true; /usr/sbin/nft -f /etc/fwmgr/fwmgr.nft'
ExecStop=-/usr/sbin/nft delete table inet fwmgr

[Install]
WantedBy=multi-user.target
UNIT
    install -m 644 "$TMP_DIR/fwmgr-nft.service" "$NFT_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || return 1
}

apply_nftables() {
    (( NFT_INSTALLED )) || { err "nftables не установлен."; return 1; }
    command -v nft >/dev/null 2>&1 || { err "Команда nft не найдена."; return 1; }
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    local bdir old_table="$TMP_DIR/old-fwmgr.nft" newfile="$TMP_DIR/new-fwmgr.nft" batch="$TMP_DIR/nft-batch.nft"
    bdir="$(make_backup_dir)"; backup_fwmgr_state "$bdir"
    local had_table=0
    if nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" > "$old_table" 2>/dev/null; then had_table=1; fi

    if [[ "$MODE" == "off" ]]; then
        if (( had_table )); then
            nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || { err "Не удалось удалить таблицу FWMgr."; return 1; }
        fi
        systemctl disable --now fwmgr-nft.service >/dev/null 2>&1 || true
        rm -f "$NFT_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -f "$NFT_FILE"
        return 0
    fi

    generate_nft_file "$newfile"
    : > "$batch"
    (( had_table )) && printf 'delete table %s %s\n' "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >> "$batch"
    cat "$newfile" >> "$batch"
    if ! nft -c -f "$batch" 2>"$TMP_DIR/nft-check.err"; then
        err "nftables отклонил конфигурацию:"
        cat "$TMP_DIR/nft-check.err" >&2 || true
        return 1
    fi
    if ! nft -f "$batch" 2>"$TMP_DIR/nft-apply.err"; then
        err "Ошибка применения nftables."
        cat "$TMP_DIR/nft-apply.err" >&2 || true
        if (( had_table )); then nft -f "$old_table" >/dev/null 2>&1 || true; else nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true; fi
        return 1
    fi
    install -m 600 "$newfile" "$NFT_FILE"
    if ! write_nft_systemd_unit; then
        err "Правила применены, но не удалось создать systemd unit. Выполняется откат."
        nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
        (( had_table )) && nft -f "$old_table" >/dev/null 2>&1 || true
        return 1
    fi
    if ! systemctl enable fwmgr-nft.service >/dev/null 2>&1; then
        err "Не удалось включить автозапуск fwmgr-nft.service. Выполняется откат."
        nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
        (( had_table )) && nft -f "$old_table" >/dev/null 2>&1 || true
        rm -f "$NFT_UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    # Mark the unit active. ExecStart recreates only table inet fwmgr.
    if ! systemctl start fwmgr-nft.service >/dev/null 2>&1; then
        err "Не удалось запустить fwmgr-nft.service. Выполняется откат."
        systemctl disable fwmgr-nft.service >/dev/null 2>&1 || true
        nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
        (( had_table )) && nft -f "$old_table" >/dev/null 2>&1 || true
        rm -f "$NFT_UNIT"; systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

write_online_timer_units() {
    local kind="$1" minutes="$2" service timer desc
    if [[ "$kind" == "blacklist" ]]; then service="$ONLINE_BLACK_SERVICE"; timer="$ONLINE_BLACK_TIMER"; desc="blacklist"; else service="$ONLINE_WHITE_SERVICE"; timer="$ONLINE_WHITE_TIMER"; desc="whitelist"; fi
    cat > "$TMP_DIR/fwmgr-online-${kind}.service" <<UNIT
[Unit]
Description=FWMgr online ${desc} update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_SCRIPT} --online-update ${kind}
UNIT
    cat > "$TMP_DIR/fwmgr-online-${kind}.timer" <<UNIT
[Unit]
Description=FWMgr online ${desc} update timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=${minutes}min
Persistent=true
Unit=fwmgr-online-${kind}.service

[Install]
WantedBy=timers.target
UNIT
    install -m 644 "$TMP_DIR/fwmgr-online-${kind}.service" "$service" || return 1
    install -m 644 "$TMP_DIR/fwmgr-online-${kind}.timer" "$timer" || return 1
}

sync_one_online_timer() {
    local kind="$1" enabled minutes urls_name service timer unit
    if [[ "$kind" == "blacklist" ]]; then
        enabled="$BLACK_ONLINE_ENABLED"; minutes="$BLACK_UPDATE_MINUTES"; urls_name="BLACK_URLS"; service="$ONLINE_BLACK_SERVICE"; timer="$ONLINE_BLACK_TIMER"; unit="fwmgr-online-blacklist.timer"
    else
        enabled="$WHITE_ONLINE_ENABLED"; minutes="$WHITE_UPDATE_MINUTES"; urls_name="WHITE_URLS"; service="$ONLINE_WHITE_SERVICE"; timer="$ONLINE_WHITE_TIMER"; unit="fwmgr-online-whitelist.timer"
    fi
    local -n urls="$urls_name"
    if [[ "$enabled" != "1" || ${#urls[@]} -eq 0 ]]; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "$service" "$timer"
        return 0
    fi
    write_online_timer_units "$kind" "$minutes" || return 1
    return 0
}

sync_online_timers() {
    [[ -x "$INSTALL_SCRIPT" ]] || { err "Системная копия FWMgr не найдена: $INSTALL_SCRIPT"; return 1; }
    sync_one_online_timer blacklist || return 1
    sync_one_online_timer whitelist || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if [[ "$BLACK_ONLINE_ENABLED" == "1" && ${#BLACK_URLS[@]} -gt 0 ]]; then
        systemctl enable fwmgr-online-blacklist.timer >/dev/null 2>&1 || return 1
        systemctl restart fwmgr-online-blacklist.timer >/dev/null 2>&1 || return 1
    fi
    if [[ "$WHITE_ONLINE_ENABLED" == "1" && ${#WHITE_URLS[@]} -gt 0 ]]; then
        systemctl enable fwmgr-online-whitelist.timer >/dev/null 2>&1 || return 1
        systemctl restart fwmgr-online-whitelist.timer >/dev/null 2>&1 || return 1
    fi
    return 0
}

run_online_update() {
    local kind="$1" enabled urls_name active_mode
    if [[ "$kind" == "blacklist" ]]; then enabled="$BLACK_ONLINE_ENABLED"; urls_name="BLACK_URLS"; active_mode="blacklist"; else enabled="$WHITE_ONLINE_ENABLED"; urls_name="WHITE_URLS"; active_mode="whitelist"; fi
    local -n urls="$urls_name"
    [[ "$enabled" == "1" && ${#urls[@]} -gt 0 ]] || return 0
    refresh_online_kind "$kind" 0 || true
    prune_online_cache "$kind"
    if [[ "$MODE" != "$active_mode" ]]; then return 0; fi
    detect_firewalls
    if (( HAS_CONFLICT )); then err "Онлайн-списки обновлены, но firewall не применен из-за конфликта: $CONFLICT_TEXT"; return 1; fi
    [[ -n "$BACKEND" ]] || BACKEND="$RESOLVED_BACKEND"
    case "$BACKEND" in
        ufw) apply_ufw ;;
        nftables) apply_nftables ;;
        *) err "Онлайн-списки обновлены, но backend firewall не определен."; return 1 ;;
    esac
}

save_settings() {
    ensure_backend || return 1
    detect_firewalls
    (( HAS_CONFLICT == 0 )) || { err "Сохранение заблокировано: $CONFLICT_TEXT"; return 1; }

    if [[ "$BLACK_ONLINE_ENABLED" == "1" && ${#BLACK_URLS[@]} -gt 0 ]]; then
        info "Обновление онлайн-источников черного списка..."
        refresh_online_kind blacklist 0 || warn "Часть источников черного списка не обновилась; используется доступный предыдущий кэш."
    else ONLINE_BLACKLIST=(); fi
    if [[ "$WHITE_ONLINE_ENABLED" == "1" && ${#WHITE_URLS[@]} -gt 0 ]]; then
        info "Обновление онлайн-источников белого списка..."
        refresh_online_kind whitelist 0 || warn "Часть источников белого списка не обновилась; используется доступный предыдущий кэш."
    else ONLINE_WHITELIST=(); fi

    protect_ssh_ip_before_save || return 1
    sort_array BLACKLIST; sort_array WHITELIST

    info "Проверка и применение правил..."
    local rc=1
    case "$BACKEND" in
        ufw) apply_ufw && rc=0 ;;
        nftables) apply_nftables && rc=0 ;;
        *) err "Backend не выбран."; return 1 ;;
    esac
    if (( rc != 0 )); then
        err "Настройки не сохранены."
        return 1
    fi
    if ! write_state_files; then
        err "Firewall применен, но не удалось записать состояние FWMgr в $STATE_DIR."
        return 1
    fi
    prune_online_cache blacklist
    prune_online_cache whitelist
    if ! sync_online_timers; then
        warn "Настройки firewall сохранены, но не удалось полностью настроить systemd-таймеры онлайн-списков."
    fi
    mark_saved
    ok "Настройки сохранены и применены."
    return 0
}

build_export_payload() {
    local out="$1"
    sort_array BLACKLIST; sort_array WHITELIST
    {
        echo "FWMGR_EXPORT_FORMAT=${FORMAT_VERSION}"
        echo "FWMGR_VERSION=${VERSION}"
        echo "MODE=${MODE}"
        echo "ACTION=${ACTION}"
        echo "BLACK_ONLINE_ENABLED=${BLACK_ONLINE_ENABLED}"
        echo "BLACK_UPDATE_MINUTES=${BLACK_UPDATE_MINUTES}"
        echo "WHITE_ONLINE_ENABLED=${WHITE_ONLINE_ENABLED}"
        echo "WHITE_UPDATE_MINUTES=${WHITE_UPDATE_MINUTES}"
        echo "[BLACKLIST]"
        ((${#BLACKLIST[@]})) && printf '%s\n' "${BLACKLIST[@]}"
        echo "[/BLACKLIST]"
        echo "[WHITELIST]"
        ((${#WHITELIST[@]})) && printf '%s\n' "${WHITELIST[@]}"
        echo "[/WHITELIST]"
        echo "[BLACK_URLS]"
        ((${#BLACK_URLS[@]})) && printf '%s\n' "${BLACK_URLS[@]}"
        echo "[/BLACK_URLS]"
        echo "[WHITE_URLS]"
        ((${#WHITE_URLS[@]})) && printf '%s\n' "${WHITE_URLS[@]}"
        echo "[/WHITE_URLS]"
    } > "$out"
}

export_to_file() {
    local ts file
    ts="$(date '+%d-%m-%Y_%H-%M-%S')"
    file="${PWD}/fwmgr_${VERSION}_${ts}.fwmgr"
    local tmp="$TMP_DIR/export.fwmgr"
    build_export_payload "$tmp"
    cp -- "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$file" 2>/dev/null || true
    fi
    ok "Экспорт создан: $file"
}

export_to_string() {
    local tmp="$TMP_DIR/export-string.fwmgr"
    build_export_payload "$tmp"
    local enc
    enc="$(base64 -w0 "$tmp")"
    msg "Скопируйте строку:"
    printf 'FWMGR:%s:%s\n' "$VERSION" "$enc"
}

parse_import_payload() {
    local file="$1"
    local parsed="$TMP_DIR/import.parsed"
    if ! python3 - "$file" > "$parsed" <<'PYIMPORT'
import ipaddress,sys,urllib.parse
p=sys.argv[1]
lines=open(p,encoding='utf-8').read().splitlines()
meta={}; sections={'BLACKLIST':[],'WHITELIST':[],'BLACK_URLS':[],'WHITE_URLS':[]}; cur=None
open_tags={f'[{x}]':x for x in sections}; close_tags={f'[/{x}]' for x in sections}
for raw in lines:
    s=raw.strip()
    if not s: continue
    if s in open_tags: cur=open_tags[s]; continue
    if s in close_tags: cur=None; continue
    if cur in ('BLACKLIST','WHITELIST'):
        try:
            if '/' in s:
                n=ipaddress.ip_network(s,strict=False)
                s=n.network_address.compressed if n.prefixlen==n.max_prefixlen else n.with_prefixlen
            else: s=ipaddress.ip_address(s).compressed
        except ValueError: raise SystemExit(f'Некорректный IP/CIDR в импорте: {s}')
        if s not in sections[cur]: sections[cur].append(s)
    elif cur in ('BLACK_URLS','WHITE_URLS'):
        u=urllib.parse.urlsplit(s)
        if u.scheme not in ('http','https') or not u.hostname or u.username or u.password:
            raise SystemExit(f'Некорректный URL онлайн-списка: {s}')
        if s not in sections[cur]: sections[cur].append(s)
    elif '=' in s:
        k,v=s.split('=',1); meta[k]=v
fmt=meta.get('FWMGR_EXPORT_FORMAT')
if fmt not in {'1','2'}: raise SystemExit('Неподдерживаемая версия формата экспорта')
if meta.get('MODE') not in {'off','blacklist','whitelist'}: raise SystemExit('Некорректный MODE')
if meta.get('ACTION') not in {'drop','reject'}: raise SystemExit('Некорректный ACTION')
def flag(name,default='0'):
    v=meta.get(name,default)
    if v not in {'0','1'}: raise SystemExit(f'Некорректный {name}')
    return v
def minutes(name,default='1440'):
    v=meta.get(name,default)
    if not v.isdigit() or int(v)<1 or int(v)>5256000: raise SystemExit(f'Некорректный {name}')
    return v
print('MODE='+meta['MODE']); print('ACTION='+meta['ACTION'])
print('BLACK_ONLINE_ENABLED='+flag('BLACK_ONLINE_ENABLED'))
print('BLACK_UPDATE_MINUTES='+minutes('BLACK_UPDATE_MINUTES'))
print('WHITE_ONLINE_ENABLED='+flag('WHITE_ONLINE_ENABLED'))
print('WHITE_UPDATE_MINUTES='+minutes('WHITE_UPDATE_MINUTES'))
for sec in ('BLACKLIST','WHITELIST','BLACK_URLS','WHITE_URLS'):
    print(f'[{sec}]'); print('\n'.join(sections[sec])); print(f'[/{sec}]')
PYIMPORT
    then
        return 1
    fi

    local section="" line
    local new_mode="" new_action="" new_bo="0" new_wo="0" new_bm="1440" new_wm="1440"
    local new_black=() new_white=() new_burls=() new_wurls=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            MODE=*) new_mode="${line#MODE=}" ;;
            ACTION=*) new_action="${line#ACTION=}" ;;
            BLACK_ONLINE_ENABLED=*) new_bo="${line#BLACK_ONLINE_ENABLED=}" ;;
            WHITE_ONLINE_ENABLED=*) new_wo="${line#WHITE_ONLINE_ENABLED=}" ;;
            BLACK_UPDATE_MINUTES=*) new_bm="${line#BLACK_UPDATE_MINUTES=}" ;;
            WHITE_UPDATE_MINUTES=*) new_wm="${line#WHITE_UPDATE_MINUTES=}" ;;
            '[BLACKLIST]') section="b" ;; '[/BLACKLIST]') section="" ;;
            '[WHITELIST]') section="w" ;; '[/WHITELIST]') section="" ;;
            '[BLACK_URLS]') section="bu" ;; '[/BLACK_URLS]') section="" ;;
            '[WHITE_URLS]') section="wu" ;; '[/WHITE_URLS]') section="" ;;
            *)
                [[ -n "$line" ]] || continue
                case "$section" in b) new_black+=("$line");; w) new_white+=("$line");; bu) new_burls+=("$line");; wu) new_wurls+=("$line");; esac
                ;;
        esac
    done < "$parsed"
    MODE="$new_mode"; ACTION="$new_action"
    BLACKLIST=("${new_black[@]}"); WHITELIST=("${new_white[@]}")
    BLACK_URLS=("${new_burls[@]}"); WHITE_URLS=("${new_wurls[@]}")
    BLACK_ONLINE_ENABLED="$new_bo"; WHITE_ONLINE_ENABLED="$new_wo"
    BLACK_UPDATE_MINUTES="$new_bm"; WHITE_UPDATE_MINUTES="$new_wm"
    sort_array BLACKLIST; sort_array WHITELIST
    load_online_cache blacklist; load_online_cache whitelist
    DIRTY=1
    ok "Настройки импортированы в FWMgr. Онлайн-кэш не переносится; источники будут загружены при сохранении."
}

import_from_file() {
    local path
    read -r -p "Абсолютный путь к файлу: " path || return
    [[ "$path" == /* ]] || { err "Нужен абсолютный путь."; return 1; }
    [[ -f "$path" ]] || { err "Файл не найден: $path"; return 1; }
    parse_import_payload "$path"
}

import_from_string() {
    local s prefix ver enc file="$TMP_DIR/import-string.fwmgr"
    read -r -p "Вставьте строку FWMgr: " s || return
    prefix="${s%%:*}"
    [[ "$prefix" == "FWMGR" ]] || { err "Неверный префикс строки."; return 1; }
    s="${s#FWMGR:}"; ver="${s%%:*}"; enc="${s#*:}"
    [[ -n "$ver" && -n "$enc" && "$enc" != "$s" ]] || { err "Некорректная строка экспорта."; return 1; }
    if ! printf '%s' "$enc" | base64 -d > "$file" 2>/dev/null; then err "Не удалось декодировать Base64."; return 1; fi
    parse_import_payload "$file"
}

export_import_menu() {
    while true; do
        clear_screen
        printf '%bЭкспорт / импорт%b\n\n' "$C_BOLD" "$C_RESET"
        msg "1. Экспортировать в файл"
        msg "2. Экспортировать в виде строки для копирования"
        msg "3. Импорт из файла"
        msg "4. Импорт из строки"
        msg "0. Назад"
        local c
        read -r -p "> " c || return
        case "$c" in
            1) export_to_file; pause_screen ;;
            2) export_to_string; pause_screen ;;
            3) import_from_file; pause_screen ;;
            4) import_from_string; pause_screen ;;
            0) return ;;
        esac
    done
}

install_firewall() {
    detect_firewalls
    if (( HAS_CONFLICT )); then err "Сначала устраните конфликт: $CONFLICT_TEXT"; pause_screen; return; fi
    if (( UFW_INSTALLED || NFT_INSTALLED )); then warn "Поддерживаемый firewall уже установлен."; pause_screen; return; fi
    if (( FIREWALLD_ACTIVE || NETFILTER_PERSISTENT_ACTIVE )); then err "Обнаружен другой активный менеджер firewall. Установка второго менеджера заблокирована."; pause_screen; return; fi

    clear_screen
    msg "Установка Firewall"
    msg "1. UFW"
    msg "2. nftables"
    msg "0. Назад"
    local c pkg
    read -r -p "> " c || return
    case "$c" in 1) pkg="ufw";; 2) pkg="nftables";; *) return;; esac
    info "Обновление списка пакетов..."
    apt-get update || { err "apt-get update завершился ошибкой."; pause_screen; return; }
    info "Установка $pkg..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || { err "Не удалось установить $pkg."; pause_screen; return; }
    MODE="off"; ACTION="drop"; BACKEND="$pkg"; [[ "$pkg" == "nftables" ]] || BACKEND="ufw"
    UFW_ENABLED_BY_FWMGR="0"
    mkdir -p "$STATE_DIR"
    if write_state_files; then
        mark_saved
        ok "$pkg установлен. FWMgr оставлен в режиме «выключен»; ограничения не добавлены."
    else
        err "$pkg установлен, но не удалось записать состояние FWMgr."
    fi
    detect_firewalls
    pause_screen
}


cleanup_online_units() {
    systemctl disable --now fwmgr-online-blacklist.timer >/dev/null 2>&1 || true
    systemctl disable --now fwmgr-online-whitelist.timer >/dev/null 2>&1 || true
    systemctl stop fwmgr-online-blacklist.service >/dev/null 2>&1 || true
    systemctl stop fwmgr-online-whitelist.service >/dev/null 2>&1 || true
    rm -f "$ONLINE_BLACK_SERVICE" "$ONLINE_BLACK_TIMER" "$ONLINE_WHITE_SERVICE" "$ONLINE_WHITE_TIMER"
}

cleanup_nft_artifacts() {
    systemctl disable --now fwmgr-nft.service >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1; then
        nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$NFT_UNIT" "$NFT_FILE"
}

cleanup_ufw_artifacts() {
    local empty="$TMP_DIR/ufw-empty.rules" b4="$TMP_DIR/uninstall-before.rules" b6="$TMP_DIR/uninstall-before6.rules"
    local changed=0
    : > "$empty"
    [[ -f /etc/ufw/before.rules ]] && cp -a /etc/ufw/before.rules "$b4"
    [[ -f /etc/ufw/before6.rules ]] && cp -a /etc/ufw/before6.rules "$b6"

    if [[ -f /etc/ufw/before.rules ]] && grep -q '# BEGIN FWMGR ' /etc/ufw/before.rules 2>/dev/null; then
        strip_and_patch_ufw_file /etc/ufw/before.rules 4 "$empty" off || {
            [[ -f "$b4" ]] && cp -a "$b4" /etc/ufw/before.rules
            return 1
        }
        changed=1
    fi
    if [[ -f /etc/ufw/before6.rules ]] && grep -q '# BEGIN FWMGR ' /etc/ufw/before6.rules 2>/dev/null; then
        strip_and_patch_ufw_file /etc/ufw/before6.rules 6 "$empty" off || {
            [[ -f "$b4" ]] && cp -a "$b4" /etc/ufw/before.rules
            [[ -f "$b6" ]] && cp -a "$b6" /etc/ufw/before6.rules
            return 1
        }
        changed=1
    fi

    if (( changed )) && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'; then
        if ! ufw reload >/dev/null 2>&1; then
            err "Не удалось перезагрузить UFW после удаления правил FWMgr. Выполняется откат файлов."
            [[ -f "$b4" ]] && cp -a "$b4" /etc/ufw/before.rules
            [[ -f "$b6" ]] && cp -a "$b6" /etc/ufw/before6.rules
            ufw reload >/dev/null 2>&1 || true
            return 1
        fi
    fi

    # Если именно FWMgr когда-то включил UFW, восстанавливаем исходное состояние disabled.
    if [[ "$UFW_ENABLED_BY_FWMGR" == "1" ]] && command -v ufw >/dev/null 2>&1; then
        ufw disable >/dev/null 2>&1 || warn "Не удалось автоматически отключить UFW, который ранее был включён FWMgr."
    fi
    return 0
}

uninstall_fwmgr() {
    clear_screen
    printf '%bУдаление FWMgr%b\n\n' "$C_BOLD" "$C_RESET"
    warn "Будут удалены только объекты, которыми владеет FWMgr: его UFW-блоки, nftables-таблица, таймеры, настройки, кэш и резервные копии."
    warn "Пакеты UFW/nftables и сторонние правила удаляться не будут."
    confirm "Полностью удалить FWMgr?" || return 1

    info "Удаление правил и systemd-объектов FWMgr..."
    cleanup_online_units
    if ! cleanup_ufw_artifacts; then
        err "Удаление остановлено: безопасно удалить UFW-блоки FWMgr не удалось. Остальные данные сохранены."
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    cleanup_nft_artifacts
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -rf "$STATE_DIR" "/var/lib/fwmgr" "$UPDATE_CACHE_DIR"
    rm -f "$COMMAND_PATH" "$LEGACY_RUNTIME_SCRIPT"
    # INSTALL_SCRIPT удаляем последним: текущий процесс продолжит работать из уже открытого файла.
    rm -f "$INSTALL_SCRIPT"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    hash -r 2>/dev/null || true

    ok "FWMgr удалён. Сторонние правила firewall и сами пакеты UFW/nftables сохранены."
    return 0
}

update_fwmgr_interactive() {
    if (( DIRTY )); then
        warn "Обновление перезапустит менеджер и несохранённые изменения будут потеряны."
        confirm "Продолжить обновление?" || return 1
    fi
    if self_update_from_github; then
        local newver
        newver="$(installed_version)"
        if [[ -n "$newver" && "$newver" != "$VERSION" ]]; then
            ok "Перезапуск FWMgr v${newver}..."
            exec "$INSTALL_SCRIPT"
        fi
    fi
}

restore_staged_from_saved() {
    MODE="$SAVED_MODE"; ACTION="$SAVED_ACTION"; BACKEND="$SAVED_BACKEND"; UFW_ENABLED_BY_FWMGR="$SAVED_UFW_ENABLED_BY_FWMGR"
    BLACKLIST=("${SAVED_BLACKLIST[@]}"); WHITELIST=("${SAVED_WHITELIST[@]}")
    BLACK_URLS=("${SAVED_BLACK_URLS[@]}"); WHITE_URLS=("${SAVED_WHITE_URLS[@]}")
    BLACK_ONLINE_ENABLED="$SAVED_BLACK_ONLINE_ENABLED"; WHITE_ONLINE_ENABLED="$SAVED_WHITE_ONLINE_ENABLED"
    BLACK_UPDATE_MINUTES="$SAVED_BLACK_UPDATE_MINUTES"; WHITE_UPDATE_MINUTES="$SAVED_WHITE_UPDATE_MINUTES"
    load_online_cache blacklist; load_online_cache whitelist
    DIRTY=0
}

main_loop() {
    while true; do
        show_main_menu
        local c
        read -r -p "> " c || c="0"
        case "$c" in
            1) if firewall_available; then cycle_mode; else warn "Пункт недоступен."; pause_screen; fi ;;
            2) if firewall_available; then toggle_action; else warn "Пункт недоступен."; pause_screen; fi ;;
            3) if firewall_available; then ensure_backend && list_menu black; else warn "Пункт недоступен."; pause_screen; fi ;;
            4) if firewall_available; then ensure_backend && list_menu white; else warn "Пункт недоступен."; pause_screen; fi ;;
            5) if firewall_available; then export_import_menu; else warn "Пункт недоступен."; pause_screen; fi ;;
            6) if firewall_available; then save_settings; pause_screen; else warn "Пункт недоступен."; pause_screen; fi ;;
            7) if uninstall_fwmgr; then return 0; else pause_screen; fi ;;
            8) update_fwmgr_interactive; pause_screen ;;
            9) install_firewall ;;
            0)
                if (( DIRTY )); then
                    if confirm "Есть несохраненные изменения. Выйти без сохранения?"; then return 0; fi
                else
                    return 0
                fi
                ;;
        esac
    done
}

# Режим установки выполняется до проверки runtime-зависимостей: локальный файл может
# установить FWMgr даже на минимальной системе, после чего зависимости проверит сама системная копия.
if [[ "$RUN_MODE" == "install" ]]; then
    install_requested_version
    exit $?
fi

# FWMgr не работает как portable-программа. Локально скачанный файл используется как
# установщик/офлайн-обновлятор и затем передаёт управление системной копии.
if [[ "$RUN_MODE" == "interactive" ]]; then
    canonical_install="$(readlink -f -- "$INSTALL_SCRIPT" 2>/dev/null || printf '%s' "$INSTALL_SCRIPT")"
    if (( !SOURCE_IS_FILE )) || [[ "$SOURCE_PATH" != "$canonical_install" ]]; then
        if (( SOURCE_IS_FILE )); then
            localver="$VERSION"
            sysver="$(installed_version)"
            if [[ -z "$sysver" ]]; then
                info "FWMgr не установлен. Установка v${localver} в систему..."
                install_system_script "$SOURCE_PATH" || exit $?
                exec "$INSTALL_SCRIPT"
            elif version_is_newer "$localver" "$sysver"; then
                warn "Обнаружена установленная FWMgr v${sysver}; запущенный файл новее: v${localver}."
                if confirm "Обновить системную версию до v${localver}?"; then
                    install_system_script "$SOURCE_PATH" || exit $?
                    exec "$INSTALL_SCRIPT"
                fi
                msg "Portable-режим отключён. Системная версия оставлена без изменений."
                exit 0
            elif version_is_newer "$sysver" "$localver"; then
                warn "Запущенный файл v${localver} старее установленной FWMgr v${sysver}. Downgrade не выполняется."
                exec "$INSTALL_SCRIPT"
            else
                # Та же версия: рабочей остаётся только системная копия.
                exec "$INSTALL_SCRIPT"
            fi
        else
            info "Потоковый запуск используется только как установщик. Получение последнего релиза..."
            install_requested_version || exit $?
            ok "Установка завершена. Для запуска используйте: sudo fwmgr"
            exit 0
        fi
    fi
fi

if ! command -v python3 >/dev/null 2>&1; then
    err "Не найден python3. Установите его: apt-get update && apt-get install -y python3"
    exit 1
fi

# CLI-обновление всегда получает опубликованный stable release; локальный более новый файл
# обновляет систему автоматически через ветку выше.
if [[ "$RUN_MODE" == "self-update" ]]; then
    self_update_from_github || exit $?
    exit 0
fi

detect_current_ip
load_state

if [[ "$RUN_MODE" == "uninstall" ]]; then
    uninstall_fwmgr
    exit $?
fi
if [[ "$RUN_MODE" == "online-update" ]]; then
    run_online_update "$UPDATE_KIND"
    exit $?
fi

# Ошибка/недоступность GitHub никак не мешает запуску менеджера.
check_for_updates 0 >/dev/null 2>&1 || true
main_loop
