#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_ROOT="$REPO_ROOT/_build/default/lib"
RUNTIME_ROOT="${HB_RUNTIME_ROOT:-$REPO_ROOT/infra/local/runtime}"
DATA_ROOT="$RUNTIME_ROOT/data"
CACHE_ROOT="$DATA_ROOT/cache-mainnet"
LMDB_DIR="$CACHE_ROOT/lmdb"
FS_CACHE_DIR="$CACHE_ROOT/fs"
PRIV_STORE_DIR="$DATA_ROOT/cache-priv"
CONFIG_PATH="$RUNTIME_ROOT/config.json"
HB_PORT="${HB_PORT:-10000}"
HB_HOST="${HB_HOST:-127.0.0.1}"
HB_MODE="${HB_MODE:-debug}"
HB_KEY="${HB_KEY:-$REPO_ROOT/hyperbeam-key.json}"
HB_LMDB_CAPACITY="${HB_LMDB_CAPACITY:-34359738368}"
HB_PRINT="${HB_PRINT:-error,http_error,cron_error,http_short}"
HB_NODE_NAME="${HB_NODE_NAME:-hb_local}"
HB_COOKIE="${HB_COOKIE:-hyperbeam-local}"
HB_DIST_PORT="${HB_DIST_PORT:-4371}"
REBAR_CMD="${REBAR_CMD:-rebar3}"
KEEP_RUNTIME="${HB_KEEP_RUNTIME:-0}"
SKIP_COMPILE="${HB_SKIP_COMPILE:-0}"

if ! command -v erl >/dev/null 2>&1; then
  echo "[run_local] Erlang (erl) is required but was not found in PATH" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[run_local] python3 is required but was not found in PATH" >&2
  exit 1
fi

if [[ "$SKIP_COMPILE" != "1" ]]; then
  (cd "$REPO_ROOT" && "$REBAR_CMD" compile >/dev/null)
fi

if [[ ! -d "$LIB_ROOT" ]]; then
  echo "[run_local] Expected build artifacts in $LIB_ROOT. Run rebar3 compile first." >&2
  exit 1
fi

mkdir -p "$LMDB_DIR" "$FS_CACHE_DIR" "$PRIV_STORE_DIR"

if [[ ! -f "$HB_KEY" ]]; then
cat >&2 <<MSG
[run_local] Missing operator wallet.
Expected key at: $HB_KEY
Set HB_KEY to the full path of your Wander/WK wallet JSON (defaults to hyperbeam-key.json in the repo root).
MSG
  exit 1
fi

ABS_KEY_PATH="$(python3 - "$HB_KEY" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
)"

python3 - "$CONFIG_PATH" "$HB_PORT" "$HB_HOST" "$HB_MODE" "$ABS_KEY_PATH" "$DATA_ROOT" "$HB_LMDB_CAPACITY" <<'PY'
import json, os, sys
config_path, port, host, mode, key_path, data_root, capacity = sys.argv[1:8]
cap = int(capacity)
cache_mainnet = os.path.join(data_root, "cache-mainnet")
config = {
    "port": int(port),
    "host": host,
    "mode": mode,
    "protocol": "http2",
    "priv_key_location": key_path,
    "lua_scripts": "scripts",
    "prometheus": True,
    "debug_print": False,
    "store_defaults": {
        "lmdb": {
            "capacity": cap
        }
    },
    "store": [
        {
            "store-module": "hb_store_lmdb",
            "name": os.path.join(cache_mainnet, "lmdb"),
            "capacity": cap,
            "ao-types": "store-module=\"atom\""
        },
        {
            "store-module": "hb_store_fs",
            "name": os.path.join(cache_mainnet, "fs"),
            "ao-types": "store-module=\"atom\""
        },
        {
            "store-module": "hb_store_gateway",
            "local-store": [
                {
                    "store-module": "hb_store_lmdb",
                    "name": os.path.join(cache_mainnet, "lmdb"),
                    "capacity": cap,
                    "ao-types": "store-module=\"atom\""
                }
            ],
            "ao-types": "store-module=\"atom\""
        }
    ],
    "priv_store": [
        {
            "store-module": "hb_store_fs",
            "name": os.path.join(data_root, "cache-priv"),
            "ao-types": "store-module=\"atom\""
        }
    ],
    "ao-types": "mode=\"atom\",protocol=\"atom\""
}
with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=4)
    handle.write("\n")
PY

declare -a ERL_PATHS
while IFS= read -r line; do
  ERL_PATHS+=("-pa" "$line")
done < <(find "$LIB_ROOT" -maxdepth 2 -type d -name ebin)

if [[ ${#ERL_PATHS[@]} -eq 0 ]]; then
  echo "[run_local] No ebin directories discovered under $LIB_ROOT" >&2
  exit 1
fi

export HB_CONFIG="$CONFIG_PATH"
export HB_PORT
export HB_KEY="$ABS_KEY_PATH"
export HB_PRINT
export HB_MODE
export ERL_LIBS="$LIB_ROOT"

declare -a ERL_CMD
ERL_CMD=(
  erl
  "${ERL_PATHS[@]}"
  -sname "$HB_NODE_NAME"
  -setcookie "$HB_COOKIE"
  -kernel inet_dist_listen_min "$HB_DIST_PORT"
  -kernel inet_dist_listen_max "$HB_DIST_PORT"
  -noshell
  -eval 'case hb_http_server:start() of {ok, _} -> receive after infinity -> ok end; Other -> io:format("HyperBEAM failed to start: ~p~n", [Other]), halt(1) end.'
)

cleanup_done=0
cleanup() {
  if [[ $cleanup_done -eq 1 ]]; then
    return
  fi
  cleanup_done=1
  if [[ -n "${BEAM_PID:-}" ]]; then
    if kill -0 "$BEAM_PID" >/dev/null 2>&1; then
      kill "$BEAM_PID" >/dev/null 2>&1 || true
      wait "$BEAM_PID" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$KEEP_RUNTIME" != "1" && -d "$RUNTIME_ROOT" ]]; then
    rm -rf "$RUNTIME_ROOT"
  fi
}

on_int() {
  cleanup
  exit 130
}

on_term() {
  cleanup
  exit 143
}

trap on_int INT
trap on_term TERM
trap cleanup EXIT

mkdir -p "$RUNTIME_ROOT"
echo "[run_local] Config written to $CONFIG_PATH"
echo "[run_local] Data root: $DATA_ROOT"

"${ERL_CMD[@]}" &
BEAM_PID=$!
wait "$BEAM_PID"
EXIT_CODE=$?
cleanup_done=1
if [[ "$KEEP_RUNTIME" != "1" && -d "$RUNTIME_ROOT" ]]; then
  rm -rf "$RUNTIME_ROOT"
fi
exit "$EXIT_CODE"
