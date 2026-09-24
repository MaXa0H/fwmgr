#!/usr/bin/env bash
# FireWall Manager v0.1 by MaXaoH
# Ubuntu-oriented interactive manager for host INPUT filtering via UFW or nftables.

set -uo pipefail

VERSION="0.1"
FORMAT_VERSION="1"
APP_TITLE="FireWall Manager v${VERSION} by MaXaoH"

STATE_DIR="/etc/fwmgr"
CONFIG_FILE="${STATE_DIR}/config"
BLACKLIST_FILE="${STATE_DIR}/blacklist"
WHITELIST_FILE="${STATE_DIR}/whitelist"
NFT_FILE="${STATE_DIR}/fwmgr.nft"
BACKUP_ROOT="/var/lib/fwmgr/backups"
LOCK_FILE="/run/lock/fwmgr.lock"
COMMAND_PATH="/usr/local/bin/fwmgr"
NFT_UNIT="/etc/systemd/system/fwmgr-nft.service"
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

need_root() {
    if (( EUID == 0 )); then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- env SSH_CONNECTION="${SSH_CONNECTION:-}" SSH_CLIENT="${SSH_CLIENT:-}" "$(readlink -f -- "${BASH_SOURCE[0]}")" "$@"
    fi
    err "Для работы FWMgr требуются права root. Запустите: sudo $0"
    exit 1
}

need_root "$@"

if ! command -v python3 >/dev/null 2>&1; then
    err "Не найден python3. Он нужен для безопасной проверки IPv4/IPv6 и CIDR."
    exit 1
fi

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    err "FWMgr уже запущен в другом процессе."
    exit 1
fi

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
TMP_DIR="$(mktemp -d /tmp/fwmgr.XXXXXX)"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

MODE="off"
ACTION="drop"
BACKEND=""
UFW_ENABLED_BY_FWMGR="0"
DIRTY=0
CURRENT_IP=""

BLACKLIST=()
WHITELIST=()
SAVED_BLACKLIST=()
SAVED_WHITELIST=()
SAVED_MODE="off"
SAVED_ACTION="drop"
SAVED_BACKEND=""
SAVED_UFW_ENABLED_BY_FWMGR="0"

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
    printf '%s' "$removed"
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

load_state() {
    local k v
    MODE="off" ACTION="drop" BACKEND="" UFW_ENABLED_BY_FWMGR="0"
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r k v || [[ -n "$k" ]]; do
            case "$k" in
                MODE) [[ "$v" =~ ^(off|blacklist|whitelist)$ ]] && MODE="$v" ;;
                ACTION) [[ "$v" =~ ^(drop|reject)$ ]] && ACTION="$v" ;;
                BACKEND) [[ "$v" =~ ^(ufw|nftables)$ ]] && BACKEND="$v" ;;
                UFW_ENABLED_BY_FWMGR) [[ "$v" =~ ^[01]$ ]] && UFW_ENABLED_BY_FWMGR="$v" ;;
            esac
        done < "$CONFIG_FILE"
    fi
    load_list_file "$BLACKLIST_FILE" BLACKLIST
    load_list_file "$WHITELIST_FILE" WHITELIST
    SAVED_MODE="$MODE"; SAVED_ACTION="$ACTION"; SAVED_BACKEND="$BACKEND"
    SAVED_UFW_ENABLED_BY_FWMGR="$UFW_ENABLED_BY_FWMGR"
    SAVED_BLACKLIST=("${BLACKLIST[@]}")
    SAVED_WHITELIST=("${WHITELIST[@]}")
    DIRTY=0
}

write_state_files() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    local cf="$TMP_DIR/config.new" bf="$TMP_DIR/blacklist.new" wf="$TMP_DIR/whitelist.new"
    cat > "$cf" <<CFG
VERSION=${VERSION}
FORMAT_VERSION=${FORMAT_VERSION}
MODE=${MODE}
ACTION=${ACTION}
BACKEND=${BACKEND}
UFW_ENABLED_BY_FWMGR=${UFW_ENABLED_BY_FWMGR}
CFG
    : > "$bf"; : > "$wf"
    sort_array BLACKLIST; sort_array WHITELIST
    ((${#BLACKLIST[@]})) && printf '%s\n' "${BLACKLIST[@]}" > "$bf"
    ((${#WHITELIST[@]})) && printf '%s\n' "${WHITELIST[@]}" > "$wf"
    install -m 600 "$cf" "$CONFIG_FILE"
    install -m 600 "$bf" "$BLACKLIST_FILE"
    install -m 600 "$wf" "$WHITELIST_FILE"
}

mark_saved() {
    SAVED_MODE="$MODE"; SAVED_ACTION="$ACTION"; SAVED_BACKEND="$BACKEND"
    SAVED_UFW_ENABLED_BY_FWMGR="$UFW_ENABLED_BY_FWMGR"
    SAVED_BLACKLIST=("${BLACKLIST[@]}")
    SAVED_WHITELIST=("${WHITELIST[@]}")
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
    printf '%b%s%b\n\n' "$C_BOLD" "$APP_TITLE" "$C_RESET"
    print_firewall_status
    printf 'Режим списков: %s\n' "$(mode_ru)"
    printf 'Отклонение соединений: %s\n' "$(action_ru)"
    printf 'Кол-во IP/подсетей в черном списке: %d\n' "${#BLACKLIST[@]}"
    printf 'Кол-во IP/подсетей в белом списке: %d\n' "${#WHITELIST[@]}"
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
    msg "8. Добавить/обновить команду fwmgr"
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

list_menu() {
    local kind="$1" arr_name title is_white=0
    if [[ "$kind" == "black" ]]; then arr_name="BLACKLIST"; title="Черный список"; else arr_name="WHITELIST"; title="Белый список"; is_white=1; fi
    while true; do
        clear_screen
        printf '%b%s%b\n\n' "$C_BOLD" "$title" "$C_RESET"
        if (( is_white )) && [[ -n "$CURRENT_IP" ]] && ! array_contains_ip WHITELIST "$CURRENT_IP"; then
            printf '%b%s%b\n\n' "$C_RED$C_BOLD" "ВНИМАНИЕ! ВАШ IP АДРЕС ОТСУТСТВУЕТ В СПИСКЕ. ПОСЛЕ СОХРАНЕНИЯ НАСТРОЕК ВЫ ПОТЕРЯЕТЕ ДОСТУП К СЕРВЕРУ" "$C_RESET"
        fi
        print_external_rules
        msg "Правила FWMgr:"
        show_managed_list "$arr_name"
        msg ""
        msg "1. Добавить IP адреса / подсети"
        msg "2. Удалить IP адреса / подсети"
        msg "3. Очистить"
        msg "0. Назад"
        local c
        read -r -p "> " c || return
        case "$c" in
            1) read_entries_multiline "$arr_name"; pause_screen ;;
            2) delete_by_numbers "$arr_name"; pause_screen ;;
            3) clear_managed_list "$arr_name" "$is_white"; pause_screen ;;
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
    removed="$(remove_entries_containing_ip BLACKLIST "$CURRENT_IP")"
    if (( removed > 0 )); then
        warn "Из черного списка удалено правил, перекрывавших ваш SSH IP ($CURRENT_IP): $removed"
        DIRTY=1
    fi
    if [[ "$MODE" == "whitelist" ]] && ! array_contains_ip WHITELIST "$CURRENT_IP"; then
        WHITELIST+=("$CURRENT_IP")
        sort_array WHITELIST
        warn "Ваш SSH IP автоматически добавлен в белый список: $CURRENT_IP"
        DIRTY=1
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
        if line.strip()==beg: inside=True; continue
        if line.strip()==end: inside=False; continue
        if not inside: out.append(line)
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
    local family="$1" out="$2" arr_name entry ver target
    : > "$out"
    printf '%s\n' "-A ${UFW_CHAIN} -i lo -j RETURN" >> "$out"
    printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" >> "$out"
    if [[ "$family" == "6" ]]; then
        # Keep IPv6 link-local control traffic functional (NDP/RA/etc.).
        printf '%s\n' "-A ${UFW_CHAIN} -s fe80::/10 -p ipv6-icmp -j RETURN" >> "$out"
        for target in destination-unreachable packet-too-big time-exceeded parameter-problem; do
            printf '%s\n' "-A ${UFW_CHAIN} -p ipv6-icmp --icmpv6-type ${target} -j RETURN" >> "$out"
        done
    fi
    if [[ "$MODE" == "blacklist" ]]; then arr_name="BLACKLIST"; else arr_name="WHITELIST"; fi
    local -n arr="$arr_name"
    for entry in "${arr[@]}"; do
        ver="$(entry_ip_version "$entry")" || continue
        [[ "$ver" == "$family" ]] || continue
        if [[ "$MODE" == "blacklist" ]]; then
            if [[ "$ACTION" == "drop" ]]; then
                printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -s ${entry} -j DROP" >> "$out"
            else
                printf '%s\n' "-A ${UFW_CHAIN} -m conntrack --ctstate NEW -s ${entry} -j REJECT" >> "$out"
            fi
        else
            printf '%s\n' "-A ${UFW_CHAIN} -s ${entry} -j RETURN" >> "$out"
        fi
    done
    if [[ "$MODE" == "whitelist" ]]; then
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
        for entry in "${BLACKLIST[@]}"; do
            ver="$(entry_ip_version "$entry")" || continue
            if [[ "$ver" == "4" ]]; then
                printf '        ct state new ip saddr %s %s\n' "$entry" "$verdict" >> "$out"
            else
                printf '        ct state new ip6 saddr %s %s\n' "$entry" "$verdict" >> "$out"
            fi
        done
    elif [[ "$MODE" == "whitelist" ]]; then
        for entry in "${WHITELIST[@]}"; do
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

save_settings() {
    ensure_backend || return 1
    detect_firewalls
    (( HAS_CONFLICT == 0 )) || { err "Сохранение заблокировано: $CONFLICT_TEXT"; return 1; }
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
        echo "[BLACKLIST]"
        ((${#BLACKLIST[@]})) && printf '%s\n' "${BLACKLIST[@]}"
        echo "[/BLACKLIST]"
        echo "[WHITELIST]"
        ((${#WHITELIST[@]})) && printf '%s\n' "${WHITELIST[@]}"
        echo "[/WHITELIST]"
    } > "$out"
}

export_to_file() {
    local ts file
    ts="$(date '+%d-%m-%Y_%H-%M-%S')"
    file="${SCRIPT_DIR}/fwmgr_${VERSION}_${ts}.fwmgr"
    local tmp="$TMP_DIR/export.fwmgr"
    build_export_payload "$tmp"
    cp -- "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
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
    if ! python3 - "$file" > "$parsed" <<'PY'
import ipaddress,sys
p=sys.argv[1]
lines=open(p,encoding='utf-8').read().splitlines()
meta={}; sections={'BLACKLIST':[],'WHITELIST':[]}; cur=None
for raw in lines:
    s=raw.strip()
    if not s: continue
    if s=='[BLACKLIST]': cur='BLACKLIST'; continue
    if s=='[/BLACKLIST]': cur=None; continue
    if s=='[WHITELIST]': cur='WHITELIST'; continue
    if s=='[/WHITELIST]': cur=None; continue
    if cur:
        try:
            if '/' in s:
                n=ipaddress.ip_network(s,strict=False)
                s=n.network_address.compressed if n.prefixlen==n.max_prefixlen else n.with_prefixlen
            else: s=ipaddress.ip_address(s).compressed
        except ValueError: raise SystemExit(f'Некорректный IP/CIDR в импорте: {s}')
        if s not in sections[cur]: sections[cur].append(s)
    elif '=' in s:
        k,v=s.split('=',1); meta[k]=v
if meta.get('FWMGR_EXPORT_FORMAT')!='1': raise SystemExit('Неподдерживаемая версия формата экспорта')
if meta.get('MODE') not in {'off','blacklist','whitelist'}: raise SystemExit('Некорректный MODE')
if meta.get('ACTION') not in {'drop','reject'}: raise SystemExit('Некорректный ACTION')
print('MODE='+meta['MODE']); print('ACTION='+meta['ACTION'])
print('[BLACKLIST]'); print('\n'.join(sections['BLACKLIST'])); print('[/BLACKLIST]')
print('[WHITELIST]'); print('\n'.join(sections['WHITELIST'])); print('[/WHITELIST]')
PY
    then
        return 1
    fi

    local section="" line
    local new_mode="" new_action="" new_black=() new_white=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            MODE=*) new_mode="${line#MODE=}" ;;
            ACTION=*) new_action="${line#ACTION=}" ;;
            '[BLACKLIST]') section="b" ;;
            '[/BLACKLIST]') section="" ;;
            '[WHITELIST]') section="w" ;;
            '[/WHITELIST]') section="" ;;
            *)
                [[ -n "$line" ]] || continue
                [[ "$section" == "b" ]] && new_black+=("$line")
                [[ "$section" == "w" ]] && new_white+=("$line")
                ;;
        esac
    done < "$parsed"
    MODE="$new_mode"; ACTION="$new_action"; BLACKLIST=("${new_black[@]}"); WHITELIST=("${new_white[@]}")
    sort_array BLACKLIST; sort_array WHITELIST
    DIRTY=1
    ok "Настройки импортированы в FWMgr. Для применения выберите «Сохранить»."
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

install_command() {
    local tmp oldver=""
    mkdir -p "$(dirname "$COMMAND_PATH")"
    if [[ -f "$COMMAND_PATH" ]]; then
        oldver="$(grep -m1 '^VERSION=' "$COMMAND_PATH" 2>/dev/null | cut -d'"' -f2 || true)"
    fi
    tmp="$(mktemp "$(dirname "$COMMAND_PATH")/.fwmgr.XXXXXX")"
    if ! install -m 0755 "$SCRIPT_PATH" "$tmp"; then rm -f "$tmp"; err "Не удалось подготовить команду."; return 1; fi
    mv -f "$tmp" "$COMMAND_PATH"
    hash -r 2>/dev/null || true
    if [[ -n "$oldver" ]]; then ok "Команда fwmgr обновлена: ${oldver} -> ${VERSION} ($COMMAND_PATH)"; else ok "Команда fwmgr установлена: $COMMAND_PATH"; fi
}

restore_staged_from_saved() {
    MODE="$SAVED_MODE"; ACTION="$SAVED_ACTION"; BACKEND="$SAVED_BACKEND"; UFW_ENABLED_BY_FWMGR="$SAVED_UFW_ENABLED_BY_FWMGR"
    BLACKLIST=("${SAVED_BLACKLIST[@]}"); WHITELIST=("${SAVED_WHITELIST[@]}")
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
            8) install_command; pause_screen ;;
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

detect_current_ip
load_state
main_loop
