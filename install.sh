#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  ___           _        _                                               │"
echo "│ |   \ ___  ___| |_____ | |__  __ _ ___ ___                              │"
echo "│ | |) / _ \/ __| / / -_)| '_ \/ _\` (_-</ -_)                             │"
echo "│ |___/\___/\___|_\_\___||_.__/\__,_/__/\___|                             │"
echo "│                                                                         │"
echo "│ Docker Control Panel - Alpha                                            │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo -e "${NC}"

# ──────────────────────────────────────────────
# Helpers (defined before flag parsing so usage
# errors and --help work unprivileged)
# ──────────────────────────────────────────────

# Escape backslash and double quote, drop control characters. Only the
# free-text JSON "message" field needs this — every other emitted value is
# charset-validated or generated hex.
json_escape() {
    printf '%s' "$1" | tr -d '\000-\037\177' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Literal newline for case-pattern guards (grep -Eq matches per LINE, so
# multi-line values must be rejected before any regex check).
NL='
'

print_usage() {
    cat << 'USAGE'
Dockebase installer

Usage:
  install.sh                    Interactive wizard (requires a terminal)
  install.sh --mode <mode> ...  Unattended install (no prompts)

Options:
  --mode <http|https-selfsigned|https-acme>
                        Proxy mode. http = plain HTTP (localhost, or external
                        TLS such as Cloudflare Tunnel); https-selfsigned =
                        self-signed certificate for IP-based access;
                        https-acme = Let's Encrypt (needs --domain + --email).
  --domain <host-or-ip> Domain or IP. Required for https-acme; optional for
                        https-selfsigned (public IP auto-detected) and for
                        http (defaults to localhost).
  --email <email>       ACME email for Let's Encrypt certificates.
  --provider <caddy|traefik>
                        Reverse proxy provider (default: caddy).
  --base-url <url>      Override the derived BASE_URL (scheme+host[:port]).
  -h, --help            Show this help and exit.

Environment variable equivalents (flags take precedence):
  DOCKEBASE_MODE, DOCKEBASE_DOMAIN, DOCKEBASE_EMAIL, DOCKEBASE_PROVIDER,
  DOCKEBASE_BASE_URL

Setting any of these switches to unattended mode: no prompts ever run, and
the last stdout line is a machine-readable result:
  DOCKEBASE_RESULT: {"status":"success",...}
  DOCKEBASE_RESULT: {"status":"error","error":"<code>","message":"..."}

Exit codes: 0 success, 1 runtime failure, 2 usage error.
USAGE
}

# Usage errors always emit the machine-readable line — a misinvoked pipe is
# most likely driven by an agent that needs a parseable failure. No colors for
# the same reason (they may fire before the unattended color reset).
usage_error() {
    print_usage >&2
    echo "" >&2
    echo "Error: $1" >&2
    echo "DOCKEBASE_RESULT: {\"status\":\"error\",\"error\":\"usage\",\"message\":\"$(json_escape "$1")\"}"
    exit 2
}

# Fatal runtime error: human message on stderr, machine-readable line on
# stdout in unattended mode (set -e alone would die without the machine line).
fail() {
    echo -e "${RED}Error: $2${NC}" >&2
    if [ "$UNATTENDED" = true ]; then
        echo "DOCKEBASE_RESULT: {\"status\":\"error\",\"error\":\"$1\",\"message\":\"$(json_escape "$2")\"}"
    fi
    exit 1
}

# Decode a raw KEY=value payload the way Compose does for the cases that
# matter to the guards: leading whitespace trimmed; a quoted value is the
# quote's content (anything after the closing quote, incl. comments, is
# dropped); an unquoted value loses an inline " #" comment and trailing
# whitespace. Deliberate residual: escape sequences inside double quotes and
# ${} interpolation are NOT re-implemented — installer-written values are
# charset-limited and never use them.
_env_decode() {
    local v="$1" lead=false
    while :; do
        case "$v" in
            " "*|"	"*) v=${v#?}; lead=true ;;
            *) break ;;
        esac
    done
    case "$v" in
        \"*)
            v=${v#\"}
            v=${v%%\"*}
            ;;
        \'*)
            v=${v#\'}
            v=${v%%\'*}
            ;;
        *)
            # A # preceded by whitespace starts a comment ("K= # x" is
            # empty); with no preceding whitespace it is literal ("K=#x").
            case "$v" in
                \#*) if [ "$lead" = true ]; then v=""; fi ;;
            esac
            v=${v%%" #"*}
            v=${v%%"	#"*}
            while :; do
                case "$v" in
                    *" "|*"	") v=${v%?} ;;
                    *) break ;;
                esac
            done
            ;;
    esac
    printf '%s' "$v"
}

# Read KEY's value from FILE (plain KEY=value lines). Never source/eval the
# file — its content must not execute. EXACT Compose semantics: the last
# occurrence wins, an empty last value included — guessing differently from
# what the running backend actually saw could resurrect a zombie key.
read_env_value() {
    _env_decode "$(grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
}

# True when KEY's LAST occurrence is (decoded-)empty while an earlier one is
# non-empty: Compose serves the empty value (the backend runs on a fallback
# key), so the earlier line is a zombie that a naive repair would resurrect
# as the active key. Such a state must be resolved by a human, never guessed.
has_shadowed_secret() {
    local last
    last=$(read_env_value "$1" "$2")
    [ -z "$last" ] || return 1
    grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- | {
        while IFS= read -r line; do
            if [ -n "$(_env_decode "$line")" ]; then exit 0; fi
        done
        exit 1
    }
}

# A usable self-bootstrap key file: a regular file (not a symlink) with
# non-blank content — mirrors the backend's read-and-trim before use, so an
# empty/whitespace file cannot satisfy the recovery guard while the backend
# would still generate a fresh key over it.
has_valid_key_file() {
    [ ! -L "$1" ] && [ -f "$1" ] && [ -n "$(tr -d '[:space:]' < "$1" 2>/dev/null)" ]
}

# Managed secrets must be LITERAL values: Compose interpolates ${...} inside
# .env (host state this script cannot see), and CR residue changes the value
# the backend reads. Guessing either way could re-key an initialized
# instance — refuse instead.
CR=$(printf '\r')
reject_unsupported_secret() {
    local body
    case "$2" in
        *'$'*)  fail recovery_required "Unsupported value in $1 in .env (contains '\$' — Compose would interpolate it). Replace it with the literal secret, then re-run." ;;
        *"$CR"*) fail recovery_required "Unsupported CRLF line ending on $1 in .env. Convert the file to LF line endings, then re-run." ;;
        *\\*)   fail recovery_required "Unsupported value in $1 in .env (contains a backslash — Compose escape processing is not replicated here). Replace it with the literal secret, then re-run." ;;
    esac
    # A quote opened on the physical line but never closed means a Compose
    # MULTILINE value — this parser is line-oriented and would silently see
    # a different (truncated) secret than the backend. Refuse.
    body="$2"
    while :; do case "$body" in " "*|"	"*) body=${body#?} ;; *) break ;; esac; done
    case "$body" in
        \"*) case "${body#?}" in *\"*) : ;; *) fail recovery_required "Unterminated double quote in $1 in .env (multiline values are unsupported). Make the value a single literal line, then re-run." ;; esac ;;
        \'*) case "${body#?}" in *\'*) : ;; *) fail recovery_required "Unterminated single quote in $1 in .env (multiline values are unsupported). Make the value a single literal line, then re-run." ;; esac ;;
    esac
}

# Raw (undecoded) last-line payload — the rejection checks above must see
# exactly what is in the file, not the decoded projection.
raw_env_value() {
    grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# Hard deadline for a command (first arg = seconds). Portable to bash 3.2 /
# systems without timeout(1): the command runs in background, a detached
# killer enforces TERM then KILL, and the script waits via the `wait`
# builtin — which, unlike a foreground child, lets INT/TERM traps fire
# immediately, so cleanup is never deferred behind a stalled Docker call.
# Two hard guarantees: (1) a fired deadline is ALWAYS a failure (flag file
# as the timeout result channel — a child that handles TERM and exits 0
# cannot fake success), and (2) the active child is tracked globally so the
# signal handler can terminate and reap it BEFORE EXIT cleanup mutates
# state it might still be writing to.
RB_ACTIVE_PID=""
RB_KILLER_PID=""
RB_PENDING=false
RB_SIG=false
RB_TIMED_OUT=false
# Deadline result channel: the killer signals the PARENT (USR1) at the exact
# moment the deadline fires, before touching the child. No file (nothing to
# sabotage) and no integer-second arithmetic (no fencepost — a fast success
# that merely crosses a SECONDS tick can never be misread as a timeout):
# status 124 if and only if the killer actually fired.
#
# HARD CALLING RULE: run_bounded must execute in the TOP-LEVEL shell — never
# inside $(...) or a pipeline. Bash 3.2 has no BASHPID and binds $$ to the
# top-level shell, and subshells reset traps, so inside a substitution the
# USR1 would target the wrong process and the timeout would be lost. When
# the command's output is needed, use run_bounded_out below.
trap 'RB_TIMED_OUT=true' USR1
run_bounded() {
    local secs="$1" cmd_pid status=0
    shift
    # Pending-signal window covers BOTH spawns (child and killer): a signal
    # landing before either PID is published must not exit (cleanup would
    # run while a child lives, or the killer would survive unreaped) —
    # on_signal only records it and returns; it is honored right after both
    # publications complete.
    RB_SIG=false
    RB_TIMED_OUT=false
    RB_PENDING=true
    "$@" &
    RB_ACTIVE_PID=$!
    cmd_pid=$RB_ACTIVE_PID
    # $$ inside the subshell is still the parent script's PID.
    ( set +e; sleep "$secs"; kill -USR1 $$ 2>/dev/null; kill -TERM "$cmd_pid" 2>/dev/null; sleep 30; kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
    RB_KILLER_PID=$!
    RB_PENDING=false
    if [ "$RB_SIG" = true ]; then
        kill -KILL "$RB_KILLER_PID" 2>/dev/null
        wait "$RB_KILLER_PID" 2>/dev/null || true
        RB_KILLER_PID=""
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 5
        kill -KILL "$cmd_pid" 2>/dev/null
        wait "$cmd_pid" 2>/dev/null || true
        RB_ACTIVE_PID=""
        exit 1
    fi
    # The USR1 trap interrupts `wait`; the child may still be running then —
    # keep waiting until it is actually reaped so its true status (and its
    # termination) are never lost.
    while :; do
        wait "$cmd_pid" 2>/dev/null
        status=$?
        if kill -0 "$cmd_pid" 2>/dev/null; then
            continue
        fi
        break
    done
    RB_ACTIVE_PID=""
    kill -KILL "$RB_KILLER_PID" 2>/dev/null
    wait "$RB_KILLER_PID" 2>/dev/null || true
    RB_KILLER_PID=""
    if [ "$RB_TIMED_OUT" = true ]; then
        status=124
    fi
    return $status
}

# Output-capturing companion that keeps run_bounded in the CURRENT shell:
# stdout goes to a private temp file and is read back into RB_OUT after
# completion, so callers never wrap run_bounded in $(...) or a pipeline
# (which would break the deadline channel — see the rule above).
RB_OUT=""
run_bounded_out() {
    local tmp status=0
    tmp=$(mktemp "${TMPDIR:-/tmp}/.dockebase-rbout.XXXXXX") || return 1
    run_bounded "$@" > "$tmp" || status=$?
    # The readback is fail-closed: an unreadable capture must never
    # masquerade as "the command succeeded with empty output" — at the
    # quiescence checks that would read as "api absent" and unlock the .env
    # rewrite while a live writer may exist. An existing command failure
    # status (124 included) is preserved over the readback failure.
    if ! RB_OUT=$(cat "$tmp" 2>/dev/null); then
        RB_OUT=""
        if [ "$status" -eq 0 ]; then
            status=1
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
    return $status
}

# INT/TERM/HUP: terminate and REAP the active bounded command AND its
# deadline killer before EXIT cleanup runs — a surviving child could mutate
# .env/containers/the lock after cleanup restored them, and a surviving
# killer could later signal a recycled PID. During the pending-signal
# window the handler only records the signal (run_bounded honors it right
# after PID publication).
on_signal() {
    trap '' INT TERM HUP
    RB_SIG=true
    if [ "$RB_PENDING" = true ]; then
        return
    fi
    if [ -n "$RB_KILLER_PID" ]; then
        kill -KILL "$RB_KILLER_PID" 2>/dev/null
        wait "$RB_KILLER_PID" 2>/dev/null || true
        RB_KILLER_PID=""
    fi
    if [ -n "$RB_ACTIVE_PID" ]; then
        kill -TERM "$RB_ACTIVE_PID" 2>/dev/null
        sleep 5
        kill -KILL "$RB_ACTIVE_PID" 2>/dev/null
        wait "$RB_ACTIVE_PID" 2>/dev/null || true
        RB_ACTIVE_PID=""
    fi
    exit 1
}

# Cleanup on every exit: if the api container was stopped for the .env
# rewrite and the run dies before docker compose up succeeded, put it back;
# release the installer lock. Registered for EXIT once the lock is taken;
# INT/TERM/HUP are routed through exit so the handler also runs on signals.
API_STOPPED=false
UP_DONE=false
PULLED=false
LOCKED=false
LOCK_DIR=""
install_cleanup() {
    local live_secret backup_secret need_restart=false restore_ok=true quiesced=false ps_out
    # A death mid-rewrite must not leave a truncated or half-updated .env
    # behind — put the pre-repair copy back through the SAME inode (bind
    # mount), so an aborted repair reverts cleanly. One exception survives
    # the rollback: a partially started api may have completed worker
    # registration and persisted the ONE-TIME instance secret into the live
    # .env — the worker never issues it again, so it is merged into the
    # restored file rather than erased with the rest.
    if [ "$UP_DONE" != true ] && [ -n "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/.env.dockebase-backup" ]; then
        # Restore ONLY under PROVEN quiescence: an unanswerable docker ps or
        # a failed stop means a live writer may still exist — touching .env
        # then could lose its one-time instance secret. A pipeline would
        # reduce a ps failure to grep's no-match; capture and check it
        # separately instead.
        quiesced=false
        if run_bounded_out 30 docker ps --format '{{.Names}}' 2>/dev/null; then
            ps_out=$RB_OUT
            if printf '%s\n' "$ps_out" | grep -qx dockebase-api; then
                if run_bounded 90 docker stop dockebase-api >/dev/null 2>&1; then
                    quiesced=true
                    need_restart=true
                fi
            else
                quiesced=true
            fi
        fi
        if [ "$quiesced" = true ]; then
            live_secret=$(read_env_value "$INSTALL_DIR/.env" DOCKEBASE_INSTANCE_SECRET 2>/dev/null) || live_secret=""
            backup_secret=$(read_env_value "$INSTALL_DIR/.env.dockebase-backup" DOCKEBASE_INSTANCE_SECRET 2>/dev/null) || backup_secret=""
            # Merge INTO THE BACKUP FIRST: the live .env is the only durable
            # holder of a newly issued one-time secret, so it must not be
            # overwritten until the secret provably exists in the copy that
            # will replace it. A failed merge leaves the live file untouched.
            if [ -n "$live_secret" ] && [ "$live_secret" != "$backup_secret" ]; then
                if ! set_env_kv "$INSTALL_DIR/.env.dockebase-backup" DOCKEBASE_INSTANCE_SECRET "$live_secret" 2>/dev/null; then
                    restore_ok=false
                fi
            fi
            if [ "$restore_ok" = true ]; then
                if ! cat "$INSTALL_DIR/.env.dockebase-backup" > "$INSTALL_DIR/.env" 2>/dev/null; then
                    restore_ok=false
                fi
            fi
            if [ "$restore_ok" = true ]; then
                rm -f "$INSTALL_DIR/.env.dockebase-backup" 2>/dev/null || true
            else
                echo "Warning: .env restore incomplete — pre-repair copy kept at $INSTALL_DIR/.env.dockebase-backup" >&2
            fi
        else
            echo "Warning: could not prove the api is stopped — .env left untouched; pre-repair copy kept at $INSTALL_DIR/.env.dockebase-backup" >&2
        fi
    fi
    if [ "$UP_DONE" != true ] && { [ "$API_STOPPED" = true ] || [ "$need_restart" = true ]; }; then
        run_bounded 60 docker start dockebase-api >/dev/null 2>&1 || true
    fi
    if [ "$LOCKED" = true ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

# Replace the ^KEY= line in FILE, or append it, preserving all other lines,
# comments and unknown keys. No sed -i (BSD/GNU divergence): temp file under
# umask 077, then mv into place. The value travels via ENVIRON, not awk -v —
# -v escape-processes backslashes, which would let a value containing "\n"
# smuggle a second line into FILE (the interactive wizard does not charset-
# validate its inputs). ENVIRON passes bytes through literally; a real
# newline is rejected outright — no legitimate value contains one.
set_env_kv() {
    local file="$1" key="$2" value="$3" tmp
    case "$value" in
        *"$NL"*) fail internal_error "refusing to write a multi-line value for $key" ;;
    esac
    # Every step is explicitly failure-propagating: this helper is also
    # called from condition contexts (the EXIT cleanup), where errexit is
    # suppressed for the whole function body — an unchecked mktemp/awk/cat
    # failure would otherwise report success.
    tmp=$(umask 077 && mktemp "${file}.XXXXXX") || return 1
    # First occurrence is replaced, later duplicates of the same key are
    # dropped — a stray duplicate line would otherwise shadow the value
    # under Compose's last-line-wins parsing.
    DOCKEBASE_SET_ENV_VALUE="$value" awk -v key="$key" '
        BEGIN { value = ENVIRON["DOCKEBASE_SET_ENV_VALUE"] }
        index($0, key "=") == 1 { if (!replaced) { print key "=" value; replaced = 1 }; next }
        { print }
        END { if (!replaced) print key "=" value }
    ' "$file" > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    # Apply with cat, not mv: Compose bind-mounts .env as a FILE into the
    # running api container, and a rename would strand that container on the
    # old inode — the backend's later instance-secret write would then never
    # reach the host copy. cat writes through the existing inode.
    cat "$tmp" > "$file" || { rm -f "$tmp" 2>/dev/null; return 1; }
    rm -f "$tmp" 2>/dev/null || true
    chmod 600 "$file" || return 1
}

# ──────────────────────────────────────────────
# CLI flags / unattended mode
# Parsed before the root check so usage errors
# and --help work unprivileged.
# ──────────────────────────────────────────────

CFG_MODE="${DOCKEBASE_MODE:-}"
CFG_DOMAIN="${DOCKEBASE_DOMAIN:-}"
CFG_EMAIL="${DOCKEBASE_EMAIL:-}"
CFG_PROVIDER="${DOCKEBASE_PROVIDER:-}"
CFG_BASE_URL="${DOCKEBASE_BASE_URL:-}"

# Presence is tracked separately from the value: an explicitly EMPTY input
# ("--mode ''", or a set-but-empty DOCKEBASE_* variable) must still select
# unattended mode and fail validation there — not fall through to the
# wizard and block on /dev/tty.
CFG_PRESENT=false
if [ -n "${DOCKEBASE_MODE+x}" ] || [ -n "${DOCKEBASE_DOMAIN+x}" ] || [ -n "${DOCKEBASE_EMAIL+x}" ] \
    || [ -n "${DOCKEBASE_PROVIDER+x}" ] || [ -n "${DOCKEBASE_BASE_URL+x}" ]; then
    CFG_PRESENT=true
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            [ $# -ge 2 ] || usage_error "--mode requires a value"
            CFG_MODE="$2"; CFG_PRESENT=true; shift 2 ;;
        --domain)
            [ $# -ge 2 ] || usage_error "--domain requires a value"
            CFG_DOMAIN="$2"; CFG_PRESENT=true; shift 2 ;;
        --email)
            [ $# -ge 2 ] || usage_error "--email requires a value"
            CFG_EMAIL="$2"; CFG_PRESENT=true; shift 2 ;;
        --provider)
            [ $# -ge 2 ] || usage_error "--provider requires a value"
            CFG_PROVIDER="$2"; CFG_PRESENT=true; shift 2 ;;
        --base-url)
            [ $# -ge 2 ] || usage_error "--base-url requires a value"
            CFG_BASE_URL="$2"; CFG_PRESENT=true; shift 2 ;;
        -h|--help)
            print_usage
            exit 0 ;;
        *)
            usage_error "Unknown option: $1" ;;
    esac
done

UNATTENDED=false
if [ "$CFG_PRESENT" = true ]; then
    UNATTENDED=true
fi

if [ "$UNATTENDED" = true ]; then
    # The consumer is an agent transcript, not a terminal: no colors, and no
    # carriage-return spinner updates below.
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' WHITE='' NC=''

    # No prompt may ever run in unattended mode — anything missing or invalid
    # is an immediate usage error. Charset guards protect .env and the JSON
    # result from injection; grep -Eq, not [[ =~ ]], for bash 3.2.
    case "$CFG_MODE" in
        http|https-selfsigned|https-acme) ;;
        "") usage_error "--mode is required in unattended mode (http, https-selfsigned or https-acme)" ;;
        *)  usage_error "Invalid --mode '$CFG_MODE' (expected http, https-selfsigned or https-acme)" ;;
    esac
    # Provider default is resolved later — a repair re-run inherits the
    # existing install's .env value rather than silently flipping to caddy.
    # Validate only an explicitly provided value here.
    if [ -n "$CFG_PROVIDER" ]; then
        case "$CFG_PROVIDER" in
            caddy|traefik) ;;
            *) usage_error "Invalid --provider '$CFG_PROVIDER' (expected caddy or traefik)" ;;
        esac
    fi
    # Provided values are validated even when the selected mode ignores them.
    # An embedded newline would let each line pass grep -Eq individually
    # ("x\nINJECT=1") — reject multi-line values first (global NL).
    if [ -n "$CFG_DOMAIN" ]; then
        case "$CFG_DOMAIN" in *"$NL"*) usage_error "Invalid --domain (contains a newline)";; esac
        printf '%s' "$CFG_DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' \
            || usage_error "Invalid --domain '$CFG_DOMAIN' (letters, digits, dots and dashes only)"
    fi
    if [ -n "$CFG_EMAIL" ]; then
        case "$CFG_EMAIL" in *"$NL"*) usage_error "Invalid --email (contains a newline)";; esac
        if [ "${#CFG_EMAIL}" -gt 254 ]; then
            usage_error "Invalid --email (longer than 254 characters)"
        fi
        printf '%s' "$CFG_EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
            || usage_error "Invalid --email '$CFG_EMAIL'"
    fi
    if [ -n "$CFG_BASE_URL" ]; then
        case "$CFG_BASE_URL" in *"$NL"*) usage_error "Invalid --base-url (contains a newline)";; esac
        printf '%s' "$CFG_BASE_URL" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]+)?$' \
            || usage_error "Invalid --base-url '$CFG_BASE_URL' (scheme + host[:port] only)"
    fi
    if [ "$CFG_MODE" = "https-acme" ]; then
        [ -n "$CFG_DOMAIN" ] || usage_error "--mode https-acme requires --domain"
        [ -n "$CFG_EMAIL" ] || usage_error "--mode https-acme requires --email"
    fi

    # Blanket guarantee for the driving agent: any command that dies under
    # set -e without an explicit || fail guard still ends with a parseable
    # result line (code internal_error). -E lets the trap fire inside
    # functions and command substitutions too.
    set -E
    trap 'echo "DOCKEBASE_RESULT: {\"status\":\"error\",\"error\":\"internal_error\",\"message\":\"unexpected failure — see stderr\"}"; exit 1' ERR
else
    # No config input: the wizard needs a terminal. A piped run without flags
    # must fail fast and parseably instead of dying on the first read.
    if { true < /dev/tty; } 2>/dev/null; then
        : # interactive wizard below
    else
        usage_error "No terminal available and no unattended flags given — pass --mode (see --help)"
    fi
fi

# Check if running as root. Runs before resolve_install_dir so an unprivileged
# run reports not_root even where install-dir resolution would fail first
# (macOS without sudo).
if [ "$EUID" -ne 0 ]; then
    fail not_root "Please run as root (sudo)"
fi

# .env must be the single source of truth for Compose interpolation. An
# exported host variable with one of these names would silently override the
# file in every docker compose call (and this script's own assignments below
# would inherit the export flag). Compose file/env-file overrides pointing
# elsewhere are dropped for the same reason.
unset DOMAIN ACME_EMAIL BASE_URL AUTH_SECRET DOCKEBASE_ENCRYPTION_KEY \
    DOCKEBASE_INSTANCE_SECRET PROXY_PROVIDER PROXY_MODE DOCKEBASE_INSTALL_DIR \
    COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROJECT_NAME COMPOSE_PROFILES \
    COMPOSE_DISABLE_ENV_FILE 2>/dev/null || true

# Install location. Linux: /opt/dockebase. macOS: the Docker VMs (Docker
# Desktop, Colima) only share /Users, /tmp and /private with the host by
# default, so bind mounts under /opt fail with "mounts denied" — install into
# the invoking user's home instead, which works with Docker Desktop, OrbStack
# and Colima without any file-sharing configuration. The same path is used
# inside and outside the container (see docker-compose.yml), so stack bind
# mounts keep working.
resolve_install_dir() {
    if [ "$(uname -s)" = "Darwin" ]; then
        local user_home
        user_home=$(eval echo "~${SUDO_USER:-root}")
        if [ -n "$SUDO_USER" ] && [ -d "$user_home" ]; then
            echo "$user_home/.dockebase"
        else
            # No silent fallback to a shared, world-writable location — that
            # would let other local users tamper with root-executed files.
            echo "Error: could not determine the invoking user's home directory." >&2
            echo "Run the installer via sudo from your normal user account:" >&2
            echo "  curl -fsSL .../install.sh | sudo bash" >&2
            exit 1
        fi
    else
        echo "/opt/dockebase"
    fi
}
INSTALL_DIR="$(resolve_install_dir)"
REPO_URL="https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main"

# Check for Docker
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    fail docker_missing "Docker is not installed. Install Docker: https://docs.docker.com/engine/install/"
fi

if ! run_bounded 30 docker compose version > /dev/null 2>&1; then
    fail compose_missing "Docker Compose v2 is not installed (it should be included with Docker Desktop or Docker Engine)"
fi

echo -e "${GREEN}✓ Docker and Docker Compose found${NC}"

# Check if Docker is running (bounded — a wedged daemon must not hang the run)
if ! run_bounded 30 docker info > /dev/null 2>&1; then
    fail docker_not_running "Docker daemon is not running (or did not answer within 30s)"
fi

echo -e "${GREEN}✓ Docker daemon is running${NC}"

# ──────────────────────────────────────────────
# Environment detection
# ──────────────────────────────────────────────

detect_environment() {
    # Try to get public IP
    local PUBLIC_IP
    # --max-time bounds the whole transfer — --connect-timeout alone would let
    # a stalling responder hang an unattended run forever.
    PUBLIC_IP=$(curl -s --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null || echo "")

    if [ -z "$PUBLIC_IP" ]; then
        echo "local"
        return
    fi

    # Check if public IP is directly on this machine (= VPS/server).
    # -F: the fetched value is data, not a regex.
    if ip addr show 2>/dev/null | grep -qwF "$PUBLIC_IP"; then
        echo "vps:$PUBLIC_IP"
    else
        echo "local"
    fi
}

# ──────────────────────────────────────────────
# Proxy provider selection
# ──────────────────────────────────────────────

ask_proxy_provider() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                                  Reverse Proxy Selection                                      ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Choose your reverse proxy:${NC}"
    echo ""
    echo -e "  ${GREEN}1) Caddy${NC} (Recommended)"
    echo -e "     • Lightweight (~20MB RAM)"
    echo -e "     • Simple configuration"
    echo ""
    echo -e "  ${BLUE}2) Traefik${NC}"
    echo -e "     • More features (~40MB RAM)"
    echo -e "     • Native Docker integration"
    echo ""
    echo -e "Enter choice [1/2] (default: 1):"
    read -r PROXY_CHOICE < /dev/tty

    case "$PROXY_CHOICE" in
        2)
            PROXY_PROVIDER="traefik"
            echo -e "${GREEN}✓ Selected: Traefik${NC}"
            ;;
        *)
            PROXY_PROVIDER="caddy"
            echo -e "${GREEN}✓ Selected: Caddy${NC}"
            ;;
    esac
}

# ──────────────────────────────────────────────
# Setup wizard (manual mode)
# ──────────────────────────────────────────────

show_wizard() {
    echo ""
    echo -e "${CYAN}Choose your setup:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Local PC/Mac (HTTP on localhost)"
    echo -e "  ${GREEN}2)${NC} Server with public IP, no domain (self-signed HTTPS)"
    echo -e "  ${GREEN}3)${NC} Server with domain (Let's Encrypt HTTPS)"
    echo -e "  ${GREEN}4)${NC} Cloudflare Tunnel (homelab, NAT, no public IP)"
    echo ""
    echo -e "Enter choice [1-4]:"
    read -r SETUP_CHOICE < /dev/tty

    case "$SETUP_CHOICE" in
        1)
            DOMAIN=localhost
            PROXY_MODE=http
            BASE_URL="http://localhost"
            PROXY_PROVIDER=caddy
            echo -e "${GREEN}✓ Configured: HTTP localhost with Caddy${NC}"
            ;;
        2)
            echo -e "\n${BLUE}Enter your server's public IP address:${NC}"
            read -r SERVER_IP < /dev/tty
            if [ -z "$SERVER_IP" ]; then
                echo -e "${RED}Error: IP address is required${NC}"
                exit 1
            fi
            DOMAIN="$SERVER_IP"
            PROXY_MODE=https-selfsigned
            BASE_URL="https://$SERVER_IP"
            ask_proxy_provider
            ;;
        3)
            echo -e "\n${BLUE}Enter your domain (e.g., panel.example.com):${NC}"
            read -r DOMAIN < /dev/tty
            if [ -z "$DOMAIN" ]; then
                echo -e "${RED}Error: Domain is required${NC}"
                exit 1
            fi
            echo -e "\n${BLUE}Enter email for Let's Encrypt SSL certificates:${NC}"
            read -r ACME_EMAIL < /dev/tty
            if [ -z "$ACME_EMAIL" ]; then
                echo -e "${RED}Error: Email is required for SSL certificates${NC}"
                exit 1
            fi
            PROXY_MODE=https-acme
            BASE_URL="https://$DOMAIN"
            ask_proxy_provider
            ;;
        4)
            echo -e "\n${BLUE}Enter your Cloudflare Tunnel URL (e.g., https://xyz.trycloudflare.com):${NC}"
            read -r TUNNEL_URL < /dev/tty
            if [ -z "$TUNNEL_URL" ]; then
                echo -e "${RED}Error: Tunnel URL is required${NC}"
                exit 1
            fi
            # Extract hostname from URL
            DOMAIN=$(echo "$TUNNEL_URL" | sed 's|https\?://||' | sed 's|/.*||')
            PROXY_MODE=http
            BASE_URL="$TUNNEL_URL"
            PROXY_PROVIDER=caddy
            echo -e "${GREEN}✓ Configured: Cloudflare Tunnel with Caddy${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# ──────────────────────────────────────────────
# Configuration (unattended or interactive)
# ──────────────────────────────────────────────

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                                       Configuration                                            ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Initialize variables
DOMAIN=""
ACME_EMAIL=""
PROXY_PROVIDER=""
PROXY_MODE=""
BASE_URL=""

if [ "$UNATTENDED" = true ]; then
    PROXY_MODE="$CFG_MODE"
    PROXY_PROVIDER="$CFG_PROVIDER"
    ACME_EMAIL="$CFG_EMAIL"
    DOMAIN="$CFG_DOMAIN"

    if [ -z "$PROXY_PROVIDER" ]; then
        # No explicit provider: inherit an existing install's value so a
        # repair re-run cannot silently flip the provider; default caddy.
        if [ -f "$INSTALL_DIR/.env" ]; then
            PROXY_PROVIDER=$(read_env_value "$INSTALL_DIR/.env" PROXY_PROVIDER)
        fi
        case "$PROXY_PROVIDER" in
            caddy|traefik) ;;
            *) PROXY_PROVIDER=caddy ;;
        esac
    fi

    if [ -z "$DOMAIN" ]; then
        case "$PROXY_MODE" in
            http)
                DOMAIN=localhost
                ;;
            https-selfsigned)
                # Reuse environment detection; only a confirmed public IP
                # bound on this machine is usable as the certificate host.
                # cut -f2- keeps a full IPv6 address together, and the same
                # charset guard as --domain then rejects it (colons) — an
                # IPv6 host would need URL brackets the proxy config doesn't
                # produce, so it must be an explicit --domain decision.
                ENV_RESULT=$(detect_environment)
                ENV_TYPE=$(echo "$ENV_RESULT" | cut -d: -f1)
                PUBLIC_IP=$(echo "$ENV_RESULT" | cut -s -d: -f2-)
                if [ "$ENV_TYPE" = "vps" ] && [ -n "$PUBLIC_IP" ] \
                    && printf '%s' "$PUBLIC_IP" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'; then
                    DOMAIN="$PUBLIC_IP"
                    echo -e "${CYAN}Detected public IP: $PUBLIC_IP${NC}"
                else
                    fail public_ip_unknown "Could not detect a usable public IP — pass --domain <ip>"
                fi
                ;;
        esac
    fi

    # BASE_URL: http + localhost stays plain HTTP; http + a real hostname
    # means TLS terminates externally (Cloudflare Tunnel — wizard scenario 4).
    if [ -n "$CFG_BASE_URL" ]; then
        BASE_URL="$CFG_BASE_URL"
    elif [ "$PROXY_MODE" = "http" ] && [ "$DOMAIN" = "localhost" ]; then
        BASE_URL="http://localhost"
    else
        BASE_URL="https://$DOMAIN"
    fi

    echo -e "${GREEN}✓ Configured: $PROXY_MODE, domain $DOMAIN, proxy $PROXY_PROVIDER, $BASE_URL${NC}"
else
    # Detect environment
    ENV_RESULT=$(detect_environment)
    ENV_TYPE=$(echo "$ENV_RESULT" | cut -d: -f1)
    PUBLIC_IP=$(echo "$ENV_RESULT" | cut -s -d: -f2)

    if [ "$ENV_TYPE" = "local" ]; then
        echo -e "${CYAN}Detected: Local machine (PC/Mac)${NC}"
        echo -e "Default: HTTP on localhost with Caddy proxy"
        echo ""
        echo -e "Press Enter to continue, or type ${YELLOW}other${NC} for more options:"
        read -r CHOICE < /dev/tty

        if [ -z "$CHOICE" ]; then
            DOMAIN=localhost
            PROXY_MODE=http
            PROXY_PROVIDER=caddy
            BASE_URL="http://localhost"
            echo -e "${GREEN}✓ Configured: HTTP localhost with Caddy${NC}"
        else
            show_wizard
        fi

    elif [ "$ENV_TYPE" = "vps" ]; then
        echo -e "${CYAN}Detected: Server with public IP ${GREEN}$PUBLIC_IP${NC}"
        echo ""
        echo -e "${BLUE}Enter your domain (e.g., panel.example.com)${NC}"
        echo -e "Leave empty for IP-based access with self-signed HTTPS:"
        read -r DOMAIN < /dev/tty

        if [ -n "$DOMAIN" ]; then
            PROXY_MODE=https-acme
            BASE_URL="https://$DOMAIN"

            echo -e "\n${BLUE}Enter email for Let's Encrypt SSL certificates:${NC}"
            read -r ACME_EMAIL < /dev/tty
            if [ -z "$ACME_EMAIL" ]; then
                echo -e "${RED}Error: Email is required for SSL certificates${NC}"
                exit 1
            fi
        else
            DOMAIN="$PUBLIC_IP"
            PROXY_MODE=https-selfsigned
            BASE_URL="https://$PUBLIC_IP"
            echo -e "${GREEN}✓ Using IP-based access with self-signed HTTPS${NC}"
        fi

        ask_proxy_provider

    else
        echo -e "${CYAN}Could not detect environment automatically.${NC}"
        show_wizard
    fi
fi

# Create installation directory. Refuse a symlink (an attacker-planted link
# would redirect root's writes) and keep the tree private — the .env written
# below carries AUTH_SECRET and the encryption key.
echo ""
echo -e "${BLUE}Creating installation directory...${NC}"
if [ -L "$INSTALL_DIR" ]; then
    fail symlink_install_dir "$INSTALL_DIR is a symlink — refusing to install into it"
fi
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"
cd "$INSTALL_DIR"

# One installer at a time: two concurrent runs could interleave the guard
# checks and the .env rewrite. mkdir is the portable atomic primitive.
LOCK_DIR="$INSTALL_DIR/.dockebase-install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail internal_error "Another installer run appears to be active (lock: $LOCK_DIR — remove it manually if it is stale)"
fi
LOCKED=true
trap install_cleanup EXIT
trap on_signal INT TERM HUP

# ── State detection and guards. Everything that can REFUSE the run happens
# here, before any live file is touched (downloads included).

# The directory guard above cannot cover a planted .env symlink — a dangling
# one even reads as "no .env" ([ -f ] follows links), and the fresh path's
# cat > .env would then write secrets through it as root.
if [ -L .env ]; then
    fail symlink_install_dir ".env is a symlink — refusing to write secrets through it"
fi

FRESH_INSTALL=true
AUTH_SECRET=""
ENCRYPTION_KEY=""
INSTANCE_SECRET_VAL=""
AUTH_SECRET_RAW=""
ENCRYPTION_KEY_RAW=""
if [ -f .env ]; then
    FRESH_INSTALL=false
    # RAW payloads are kept for the write-back: rewriting a quoted value in
    # its decoded form would change what Compose reads ("abc # def" written
    # unquoted becomes abc). Decoded values serve the guards only.
    AUTH_SECRET_RAW=$(raw_env_value .env AUTH_SECRET)
    ENCRYPTION_KEY_RAW=$(raw_env_value .env DOCKEBASE_ENCRYPTION_KEY)
    reject_unsupported_secret AUTH_SECRET "$AUTH_SECRET_RAW"
    reject_unsupported_secret DOCKEBASE_ENCRYPTION_KEY "$ENCRYPTION_KEY_RAW"
    reject_unsupported_secret DOCKEBASE_INSTANCE_SECRET "$(raw_env_value .env DOCKEBASE_INSTANCE_SECRET)"
    AUTH_SECRET=$(read_env_value .env AUTH_SECRET)
    ENCRYPTION_KEY=$(read_env_value .env DOCKEBASE_ENCRYPTION_KEY)
    INSTANCE_SECRET_VAL=$(read_env_value .env DOCKEBASE_INSTANCE_SECRET)
    # Conflicting duplicates are never guessed at — see has_shadowed_secret.
    if has_shadowed_secret .env AUTH_SECRET; then
        fail recovery_required "Conflicting duplicate AUTH_SECRET lines in .env (an earlier non-empty value is shadowed by a later empty one). Resolve the duplicates manually, then re-run."
    fi
    if has_shadowed_secret .env DOCKEBASE_ENCRYPTION_KEY; then
        fail recovery_required "Conflicting duplicate DOCKEBASE_ENCRYPTION_KEY lines in .env (an earlier non-empty value is shadowed by a later empty one). The backend is running on a fallback key — resolve the duplicates manually, then re-run."
    fi
fi
DB_EXISTS=false
if [ -f "$INSTALL_DIR/data/dockebase.db" ]; then
    DB_EXISTS=true
fi

# A present-but-nonregular key/marker file is refused UNCONDITIONALLY —
# regardless of which key source would be used. The backend refuses these on
# boot, so proceeding here (e.g. on the instance-secret path) would stop a
# working api and then fail to bring it back.
for _keyfile in "$INSTALL_DIR/data/.encryption-key" "$INSTALL_DIR/data/.encryption-key-backup-pending"; do
    if [ -L "$_keyfile" ] || { [ -e "$_keyfile" ] && [ ! -f "$_keyfile" ]; }; then
        fail recovery_required "$_keyfile is not a regular file (symlink or special node) — the backend refuses it too. Fix it manually, then re-run."
    fi
done

# An EMPTY (or whitespace-only) regular key file is refused too — the
# backend fails closed on it at boot, so accepting it here (e.g. on the
# legacy instance-secret path) would stop a working api that then cannot
# come back. (The marker file is legitimately empty and is not checked.)
if [ -e "$INSTALL_DIR/data/.encryption-key" ] && ! has_valid_key_file "$INSTALL_DIR/data/.encryption-key"; then
    fail recovery_required "$INSTALL_DIR/data/.encryption-key exists but is empty — the backend refuses to boot on it. Remove the file manually (an empty file cannot be the active key), then re-run."
fi

# An initialized database must never be re-keyed or silently re-adopted:
# without .env there is no config baseline, and without any encryption key —
# not in .env, no legacy DOCKEBASE_INSTANCE_SECRET (a valid fallback the
# backend derives from), no usable self-bootstrap key file — the key is
# LOST. Proceeding would let the backend mint a fresh key and permanently
# orphan everything already encrypted.
if [ "$DB_EXISTS" = true ]; then
    if [ "$FRESH_INSTALL" = true ]; then
        fail recovery_required "An initialized database exists at $INSTALL_DIR/data/dockebase.db but .env is missing. Restore .env from a backup — or, if this instance never completed its first start, remove it with delete.sh and install fresh."
    fi
    if [ -z "$ENCRYPTION_KEY" ] && [ -z "$INSTANCE_SECRET_VAL" ] \
        && ! has_valid_key_file "$INSTALL_DIR/data/.encryption-key"; then
        fail recovery_required "An initialized database exists but no encryption key was found (missing/empty in .env, no instance secret, no usable data/.encryption-key). Restore the key from your backup — or, if this instance never completed its first start, remove it with delete.sh and install fresh. Continuing would orphan all encrypted data."
    fi
fi

# An initialized instance takes domain/mode/provider from its DATABASE
# (webserver_config, written on first boot), not from .env — an .env-only
# change would restart the stack and then report a configuration that never
# becomes effective. Once the database exists, refuse config changes; a
# same-config re-run (repair) proceeds. Config changes belong in the panel
# (Settings), or uninstall via delete.sh.
if [ "$FRESH_INSTALL" = false ] && [ "$DB_EXISTS" = true ]; then
    CUR_DOMAIN=$(read_env_value .env DOMAIN)
    CUR_MODE=$(read_env_value .env PROXY_MODE)
    CUR_PROVIDER=$(read_env_value .env PROXY_PROVIDER)
    CUR_BASE_URL=$(read_env_value .env BASE_URL)
    if [ "$CUR_DOMAIN" != "$DOMAIN" ] || [ "$CUR_MODE" != "$PROXY_MODE" ] \
        || [ "$CUR_PROVIDER" != "$PROXY_PROVIDER" ] || [ "$CUR_BASE_URL" != "$BASE_URL" ]; then
        fail reconfigure_unsupported "This instance is already configured (domain '$CUR_DOMAIN', mode '$CUR_MODE', provider '$CUR_PROVIDER'). Re-running the installer cannot change an initialized instance — use the Dockebase panel (Settings), or uninstall first with delete.sh. If the panel already runs the configuration you asked for, re-run WITHOUT the changed flag — a repair inherits existing values."
    fi
fi

# Downloads are bounded and staged through a temp name so a cut transfer
# never leaves a truncated live file.
echo -e "${BLUE}Downloading configuration files...${NC}"
if ! curl -fsSL --connect-timeout 10 --max-time 120 "$REPO_URL/docker-compose.yml" -o docker-compose.yml.tmp; then
    rm -f docker-compose.yml.tmp
    fail download_failed "Failed to download docker-compose.yml from $REPO_URL"
fi
mv docker-compose.yml.tmp docker-compose.yml
if ! curl -fsSL --connect-timeout 10 --max-time 120 "$REPO_URL/.env.example" -o .env.example.tmp; then
    rm -f .env.example.tmp
    fail download_failed "Failed to download .env.example from $REPO_URL"
fi
mv .env.example.tmp .env.example

echo -e "${GREEN}✓ Configuration files downloaded${NC}"

# Create or update .env. A re-run is a REPAIR: existing non-empty secrets
# are NEVER regenerated — DOCKEBASE_ENCRYPTION_KEY in particular guards
# already-encrypted stack env vars, and regenerating it would silently lose
# that data. (State detection and the refusal guards ran above, before the
# downloads.)
echo ""
echo -e "${BLUE}Creating configuration...${NC}"

if [ "$FRESH_INSTALL" = false ]; then
    echo -e "${YELLOW}Existing installation detected — keeping existing secrets.${NC}"
fi
if [ -z "$AUTH_SECRET" ]; then
    AUTH_SECRET=$(openssl rand -hex 32)
    AUTH_SECRET_RAW="$AUTH_SECRET"
fi
# DOCKEBASE_ENCRYPTION_KEY is deliberately NOT generated here: on first boot
# the backend generates it into data/.encryption-key and the panel shows it
# exactly once to the authenticated human during onboarding (with a forced
# backup acknowledgment). Keeping it out of installer stdout keeps it out of
# agent transcripts and CI logs. An existing non-empty key in .env is
# preserved untouched.
# Note: DOCKEBASE_INSTANCE_SECRET is generated by the worker and saved automatically

if [ "$FRESH_INSTALL" = true ]; then
    cat > .env << EOF
# Dockebase Configuration
# Generated by install.sh

DOMAIN=$DOMAIN
ACME_EMAIL=${ACME_EMAIL:-}
BASE_URL=$BASE_URL
AUTH_SECRET=$AUTH_SECRET
DOCKEBASE_ENCRYPTION_KEY=
DOCKEBASE_INSTANCE_SECRET=
PROXY_PROVIDER=$PROXY_PROVIDER
PROXY_MODE=$PROXY_MODE
DOCKEBASE_INSTALL_DIR=$INSTALL_DIR
EOF
else
    # Images are pulled BEFORE the api is stopped, so a slow or failing pull
    # cannot extend the outage window (the global pull is then skipped).
    # --env-file .env everywhere: the file must stay authoritative even if
    # the host exported Compose overrides the unset above did not cover.
    run_bounded 900 docker compose --env-file .env pull || fail pull_failed "docker compose pull failed (or exceeded 15 minutes)"
    PULLED=true
    # The api container must not be running while .env is rewritten — the
    # backend can write DOCKEBASE_INSTANCE_SECRET into it at any moment
    # (worker registration), and a write landing between set_env_kv's awk
    # snapshot and its cat apply would be silently lost. A failed status
    # query is NOT "not running" — it must abort. API_STOPPED is pre-marked
    # before the stop attempt so the EXIT handler restores the container
    # even when the stop itself is interrupted midway (docker start on a
    # still-running container is a no-op).
    if ! run_bounded_out 30 docker ps --format '{{.Names}}' 2>/dev/null; then
        fail internal_error "Could not query Docker for running containers before rewriting .env"
    fi
    PS_NAMES=$RB_OUT
    if printf '%s\n' "$PS_NAMES" | grep -qx dockebase-api; then
        API_STOPPED=true
        run_bounded 90 docker stop dockebase-api >/dev/null 2>&1 \
            || fail internal_error "Could not stop dockebase-api before rewriting .env"
    fi
    # Crash-recovery copy: set_env_kv rewrites the live file in place (inode
    # preservation for the bind mount) — a hard kill mid-write could leave
    # it truncated. Removed again after a successful compose up.
    cp -p .env .env.dockebase-backup \
        || fail internal_error "Could not create the .env recovery copy"
    set_env_kv .env DOMAIN "$DOMAIN"
    set_env_kv .env ACME_EMAIL "${ACME_EMAIL:-}"
    set_env_kv .env BASE_URL "$BASE_URL"
    # Secrets are written back in their ORIGINAL RAW serialization (quotes
    # included) — the decoded projection is guard-only, and rewriting a
    # quoted value unquoted would change what Compose reads ("abc # def"
    # rewritten bare truncates at the comment). The write travels via
    # ENVIRON (never awk -v) and doubles as duplicate-line normalization.
    set_env_kv .env AUTH_SECRET "$AUTH_SECRET_RAW"
    set_env_kv .env DOCKEBASE_ENCRYPTION_KEY "$ENCRYPTION_KEY_RAW"
    # DOCKEBASE_INSTANCE_SECRET is written by the backend, never generated
    # here — keep its value as-is, just make sure the line exists.
    if ! grep -Eq '^DOCKEBASE_INSTANCE_SECRET=' .env; then
        set_env_kv .env DOCKEBASE_INSTANCE_SECRET ""
    fi
    set_env_kv .env PROXY_PROVIDER "$PROXY_PROVIDER"
    set_env_kv .env PROXY_MODE "$PROXY_MODE"
    set_env_kv .env DOCKEBASE_INSTALL_DIR "$INSTALL_DIR"
fi
# Secrets inside — never world-readable (umask 022 would make it so)
chmod 600 .env

echo -e "${GREEN}✓ Configuration created${NC}"

# Create data directory for bind mount
# This is required for stack bind mounts to work (Docker socket runs on host)
echo -e "${BLUE}Creating data directory...${NC}"
mkdir -p "$INSTALL_DIR/data/stacks"

# macOS: the script runs under sudo but the install dir lives in the user's
# home — hand ownership back so the panel files are manageable without root
if [ "$(uname -s)" = "Darwin" ] && [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER" "$INSTALL_DIR" 2>/dev/null || true
fi
echo -e "${GREEN}✓ Data directory created${NC}"

# Create Docker networks
echo -e "${BLUE}Creating Docker networks...${NC}"
run_bounded 30 docker network create dockebase-internal 2>/dev/null || true
run_bounded 30 docker network create dockebase-proxy 2>/dev/null || true
echo -e "${GREEN}✓ Docker networks created${NC}"

# Pull images (already done on the repair path, before the api was stopped)
if [ "$PULLED" != true ]; then
    echo ""
    echo -e "${BLUE}Pulling Docker images...${NC}"
    run_bounded 900 docker compose --env-file .env pull || fail pull_failed "docker compose pull failed (or exceeded 15 minutes)"
    echo -e "${GREEN}✓ Images pulled${NC}"
fi

# Start services
echo ""
echo -e "${BLUE}Starting Dockebase...${NC}"
run_bounded 300 docker compose --env-file .env up -d || fail compose_up_failed "docker compose up -d failed (or exceeded 5 minutes)"
UP_DONE=true
rm -f "$INSTALL_DIR/.env.dockebase-backup" 2>/dev/null || true

echo -e "${GREEN}✓ Dockebase started${NC}"

# Wait for containers to be running
echo ""
MAX_WAIT=60
if [ "$UNATTENDED" = true ]; then
    echo "Waiting up to ${MAX_WAIT}s for services to start..."
else
    echo -e "${BLUE}Waiting for services to start...${NC}"
fi
# Wall-clock deadline (SECONDS builtin): stalled bounded polls must not
# stretch the advertised wait — the loop ends by elapsed time, not by a
# count of completed iterations.
WAIT_START=$SECONDS
SERVICES_OK=false
while [ $((SECONDS - WAIT_START)) -lt $MAX_WAIT ]; do
    if run_bounded_out 20 docker inspect --format '{{.State.Status}}' dockebase-api 2>/dev/null; then
        API_STATUS=$RB_OUT
    else
        API_STATUS="missing"
    fi
    if run_bounded_out 20 docker inspect --format '{{.State.Status}}' dockebase-ui 2>/dev/null; then
        UI_STATUS=$RB_OUT
    else
        UI_STATUS="missing"
    fi

    if [ "$API_STATUS" = "running" ] && [ "$UI_STATUS" = "running" ]; then
        [ "$UNATTENDED" = true ] || printf "\r\033[K"
        echo -e "${GREEN}✓ Services are running${NC}"
        SERVICES_OK=true
        break
    fi

    if [ "$UNATTENDED" != true ]; then
        REMAINING=$((MAX_WAIT - (SECONDS - WAIT_START)))
        printf "\r  Waiting for containers... (%ds remaining)" "$REMAINING"
    fi
    sleep 2
done

if [ "$SERVICES_OK" = false ]; then
    [ "$UNATTENDED" = true ] || printf "\r\033[K"
    echo "Check status with: cd $INSTALL_DIR && docker compose ps" >&2
    echo "Check logs with: cd $INSTALL_DIR && docker compose logs" >&2
    fail services_not_running "Services did not start within ${MAX_WAIT}s"
fi

# Wait for proxy to be initialized by the backend
MAX_WAIT=45
if [ "$UNATTENDED" = true ]; then
    echo "Waiting up to ${MAX_WAIT}s for proxy to initialize..."
else
    echo -e "${BLUE}Waiting for proxy to initialize...${NC}"
fi
WAIT_START=$SECONDS
PROXY_OK=false
PROXY_CONTAINER=""
EFFECTIVE_PROVIDER="$PROXY_PROVIDER"
while [ $((SECONDS - WAIT_START)) -lt $MAX_WAIT ]; do
    # Match either provider: after a panel-side provider switch the DATABASE
    # — not .env — decides which proxy container the backend creates.
    PROXY_CONTAINER=""
    if run_bounded_out 20 docker ps --format '{{.Names}}' 2>/dev/null; then
        PROXY_CONTAINER=$(printf '%s\n' "$RB_OUT" | grep -E -m1 '^dockebase-(caddy|traefik)$' || true)
    fi
    if [ -n "$PROXY_CONTAINER" ]; then
        EFFECTIVE_PROVIDER="${PROXY_CONTAINER#dockebase-}"
        [ "$UNATTENDED" = true ] || printf "\r\033[K"
        echo -e "${GREEN}✓ Proxy ($EFFECTIVE_PROVIDER) is running${NC}"
        PROXY_OK=true
        break
    fi

    if [ "$UNATTENDED" != true ]; then
        REMAINING=$((MAX_WAIT - (SECONDS - WAIT_START)))
        printf "\r  Starting proxy... (%ds remaining)" "$REMAINING"
    fi
    sleep 3
done

if [ "$PROXY_OK" = false ]; then
    [ "$UNATTENDED" = true ] || printf "\r\033[K"
    echo -e "${YELLOW}Note: Proxy may still be starting. Check logs for details.${NC}"
    echo "  docker compose logs dockebase-api | grep Proxy"
fi

# Print success message
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                              Dockebase Installation Complete!                              ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

case "$PROXY_MODE" in
    http)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        if [ "$DOMAIN" = "localhost" ]; then
            echo -e "${YELLOW}Running in HTTP mode on localhost.${NC}"
        else
            echo -e "${YELLOW}Running in HTTP mode (SSL handled externally).${NC}"
        fi
        ;;
    https-selfsigned)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        echo -e "${YELLOW}Using self-signed HTTPS certificate.${NC}"
        echo -e "${YELLOW}Your browser will show a security warning — this is expected.${NC}"
        ;;
    https-acme)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        echo -e "Proxy: ${CYAN}$EFFECTIVE_PROVIDER${NC}"
        echo -e "${YELLOW}SSL certificate will be automatically provisioned via Let's Encrypt.${NC}"
        echo -e "${YELLOW}This may take a few minutes on first access.${NC}"
        ;;
esac

echo ""
echo -e "Installation directory: ${BLUE}$INSTALL_DIR${NC}"
echo ""
echo -e "${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${RED}                                        IMPORTANT                                         ${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Back up your encryption key.${NC}"
echo ""
if [ -n "$ENCRYPTION_KEY" ]; then
    echo -e "${YELLOW}Your existing DOCKEBASE_ENCRYPTION_KEY in .env was preserved —${NC}"
    echo -e "${YELLOW}make sure it is backed up in a secure location.${NC}"
elif [ -n "$INSTANCE_SECRET_VAL" ] && ! has_valid_key_file "$INSTALL_DIR/data/.encryption-key"; then
    echo -e "${YELLOW}This legacy install encrypts with DOCKEBASE_INSTANCE_SECRET from .env —${NC}"
    echo -e "${YELLOW}that value is the recovery material; make sure .env is backed up.${NC}"
elif [ "$DB_EXISTS" = true ] && has_valid_key_file "$INSTALL_DIR/data/.encryption-key" \
    && [ ! -f "$INSTALL_DIR/data/.encryption-key-backup-pending" ]; then
    echo -e "${YELLOW}Your key is stored in data/.encryption-key on this server (it was${NC}"
    echo -e "${YELLOW}already shown during onboarding) — make sure it is backed up.${NC}"
else
    echo -e "${YELLOW}The panel will show the key ONCE during onboarding — store it in a${NC}"
    echo -e "${YELLOW}password manager when prompted. It is never printed here.${NC}"
fi
echo ""
echo -e "${YELLOW}This key encrypts your stack environment variables.${NC}"
echo -e "${YELLOW}If you lose it, encrypted data cannot be recovered.${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Useful commands:"
echo -e "  ${BLUE}cd $INSTALL_DIR${NC}"
echo -e "  ${BLUE}docker compose ps${NC}          - Check services status"
echo -e "  ${BLUE}docker compose logs -f${NC}     - View logs"
echo -e "  ${BLUE}docker compose down${NC}        - Stop services"
echo -e "  ${BLUE}docker compose up -d${NC}       - Start services"
echo ""

# Machine-readable result — must be the very last stdout line. The
# encryption key itself is deliberately absent: agent transcripts and CI
# logs outlive any .env retention. The field only says where the human
# backs the key up.
if [ "$UNATTENDED" = true ]; then
    if [ "$SERVICES_OK" = true ]; then SERVICES_STATE="running"; else SERVICES_STATE="not_running"; fi
    if [ "$PROXY_OK" = true ]; then PROXY_STATE="running"; else PROXY_STATE="pending"; fi
    if [ -n "$ENCRYPTION_KEY" ]; then KEY_BACKUP="env_preserved"
    elif [ -n "$INSTANCE_SECRET_VAL" ] && ! has_valid_key_file "$INSTALL_DIR/data/.encryption-key"; then
        KEY_BACKUP="instance_secret"
    elif [ "$DB_EXISTS" = true ] && has_valid_key_file "$INSTALL_DIR/data/.encryption-key" \
        && [ ! -f "$INSTALL_DIR/data/.encryption-key-backup-pending" ]; then KEY_BACKUP="key_file"
    else KEY_BACKUP="onboarding"
    fi
    echo "DOCKEBASE_RESULT: {\"status\":\"success\",\"fresh_install\":$FRESH_INSTALL,\"mode\":\"$PROXY_MODE\",\"provider\":\"$EFFECTIVE_PROVIDER\",\"url\":\"$BASE_URL\",\"install_dir\":\"$(json_escape "$INSTALL_DIR")\",\"services\":\"$SERVICES_STATE\",\"proxy\":\"$PROXY_STATE\",\"encryption_key_backup\":\"$KEY_BACKUP\"}"
fi
