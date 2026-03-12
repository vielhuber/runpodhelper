#!/usr/bin/env bash

set -euo pipefail

# -------------------------------------------------------------------
# Load config
# -------------------------------------------------------------------
# PACKAGE_DIR resolves symlinks so vendor/bin/runpod.sh works correctly
PACKAGE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$PWD"
CONFIG="${PROJECT_DIR}/models.yaml"
ENV_FILE="${PROJECT_DIR}/.env"

# Load .env for RUNPOD_API_KEY and other secrets (strip Windows CR line endings)
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source <(sed 's/\r//' "$ENV_FILE")
    set +a
fi

if [[ ! -f "$CONFIG" ]]; then
    if [[ "${1:-}" == "init" ]]; then
        CONFIG_JSON='{}'
    else
        echo "[ERROR] Config file not found: ${CONFIG}" >&2
        exit 1
    fi
fi

# Convert YAML to JSON once at startup so all jq calls can use standard JSON parsing
if [[ -z "${CONFIG_JSON:-}" ]]; then
    CONFIG_JSON=$(python3 -c "
import sys, json, re
try:
    import yaml
except ImportError:
    sys.exit('[ERROR] Python yaml module not found. Run: pip install pyyaml')

class PreserveLeadingZeroLoader(yaml.SafeLoader):
    pass

PreserveLeadingZeroLoader.yaml_implicit_resolvers = {
    key: value[:] for key, value in yaml.SafeLoader.yaml_implicit_resolvers.items()
}

for key, resolvers in PreserveLeadingZeroLoader.yaml_implicit_resolvers.items():
    PreserveLeadingZeroLoader.yaml_implicit_resolvers[key] = [
        (tag, pattern) for tag, pattern in resolvers if tag != 'tag:yaml.org,2002:int'
    ]

PreserveLeadingZeroLoader.add_implicit_resolver(
    'tag:yaml.org,2002:int',
    re.compile(r'^(?:[-+]?(?:0|[1-9][0-9_]*))$'),
    list('-+0123456789'),
)

with open('${CONFIG}') as f:
    print(json.dumps(yaml.load(f, Loader=PreserveLeadingZeroLoader)))
") || exit 1
fi

IMAGE="${RUNPOD_IMAGE:-runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04}"
SSH_KEY=$(eval echo "${RUNPOD_SSH_KEY:-~/.ssh/id_ed25519}")
RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"

# Load SSH public key lazily (only when needed)
load_ssh_pubkey() {
    if [[ -z "${SSH_PUBKEY:-}" ]]; then
        SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"
    fi
}

SSH_DAEMON_ARGS='bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server && mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo $MY_SSH_PUBLIC_KEY >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh/authorized_keys && ssh-keygen -A && service ssh start; if [[ -x /usr/local/bin/runpod-lmstudio-autostart.sh ]]; then /usr/local/bin/runpod-lmstudio-autostart.sh > /var/log/runpod-lmstudio-autostart.log 2>&1 || cat /var/log/runpod-lmstudio-autostart.log; fi; sleep infinity"'

# -------------------------------------------------------------------
# RunPod GraphQL API helper
# -------------------------------------------------------------------
runpod_api() {
    local query="$1"
    if [[ -z "$RUNPOD_API_KEY" ]]; then
        log_error "RUNPOD_API_KEY must be set in runpod/.env. Get it from https://www.runpod.io/console/user/settings"
        exit 1
    fi
    curl -sSL --max-time 30 -X POST \
        "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "$query"
}

# -------------------------------------------------------------------
# Colors
# -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -------------------------------------------------------------------
# Dynamic pod lookup via RunPod GraphQL API
# -------------------------------------------------------------------

# Derive a runtime pod name from the configured pod ID.
pod_name_from_config_id() {
    local pod_config_id="$1"
    echo "lmstudio-pod-$(echo "$pod_config_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')"
}

format_pod_display_id() {
    local pod_config_id="$1"
    if [[ "$pod_config_id" =~ ^[0-9]+$ ]]; then
        printf '%03d' "$((10#$pod_config_id))"
        return 0
    fi
    printf '%s' "$pod_config_id"
}

pod_display_name_from_config_id() {
    local pod_config_id="$1"
    printf 'lmstudio-pod-%s' "$(format_pod_display_id "$pod_config_id")"
}

legacy_numeric_pod_name_from_config_id() {
    local pod_config_id="$1"
    if [[ "$pod_config_id" =~ ^[0-9]+$ ]]; then
        printf 'lmstudio-pod-%d' "$((10#$pod_config_id))"
        return 0
    fi
    printf 'lmstudio-pod-%s' "$pod_config_id"
}

pod_config_id_from_name() {
    local pod_name="$1"
    local prefix="lmstudio-pod-"
    if [[ "$pod_name" == ${prefix}* ]]; then
        echo "${pod_name#$prefix}"
        return 0
    fi
    return 1
}

deployment_model_id_from_pod_config_id() {
    local pod_config_id="$1"
    echo "$CONFIG_JSON" | jq -r --arg id "$pod_config_id" 'first((.pods // [])[] | select((.id | tostring) == $id) | .model) // ""'
}

model_url_from_model_id() {
    local model_id="$1"
    echo "$CONFIG_JSON" | jq -r --arg id "$model_id" 'first((.models // [])[] | select(.id == $id) | .url) // ""'
}

model_url_from_pod_config_id() {
    local pod_config_id="$1"
    local model_id
    model_id=$(echo "$CONFIG_JSON" | jq -r --arg id "$pod_config_id" 'first((.pods // [])[] | select((.id | tostring) == $id) | .model) // ""')
    model_url_from_model_id "$model_id"
}

# Returns JSON array of all configured pods via the RunPod GraphQL API.
our_pods_json() {
    local response
    response=$(runpod_api '{"query":"{ myself { pods { id name desiredStatus machine { gpuDisplayName } } } }"}') || response=''
    echo "$response" | python3 -c "
import json, sys
try:
    pods = json.load(sys.stdin)['data']['myself']['pods']
    result = [p for p in pods if p.get('name', '').startswith('lmstudio-')]
    result.sort(key=lambda p: p.get('name', ''))
    print(json.dumps(result))
except Exception:
    print('[]')
" 2> /dev/null || echo '[]'
}

# Returns desiredStatus for a given pod ID via the RunPod GraphQL API.
pod_status() {
    local pod_id="$1"
    local payload response
    payload=$(printf '{"query":"{ pod(input: { podId: \\"%s\\" }) { desiredStatus } }"}' "$pod_id")
    response=$(runpod_api "$payload") || response=''
    echo "$response" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin)['data']['pod']['desiredStatus'])
except Exception:
    print('UNKNOWN')
" 2> /dev/null || echo 'UNKNOWN'
}

# Returns SSH host and port for a given pod ID (format "host port").
# Polls the RunPod GraphQL API for runtime.ports, retries up to 120s.
pod_ssh_details() {
    local pod_id="$1"
    local max_wait=120 elapsed=0
    local payload
    payload=$(printf '{"query":"{ pod(input: { podId: \\"%s\\" }) { runtime { ports { ip publicPort privatePort } } } }"}' "$pod_id")
    while [[ $elapsed -lt $max_wait ]]; do
        local response entry
        response=$(runpod_api "$payload") || response=''
        entry=$(echo "$response" | python3 -c "
import json, sys
try:
    ports = json.load(sys.stdin)['data']['pod']['runtime']['ports'] or []
    for p in ports:
        if str(p.get('privatePort')) == '22' and p.get('ip') and p.get('publicPort'):
            print(str(p['ip']) + ' ' + str(p['publicPort']))
            break
except Exception:
    pass
" 2> /dev/null || true)
        if [[ -n "$entry" ]]; then
            echo "$entry"
            return 0
        fi
        log_info "Waiting for SSH port on pod ${pod_id}... (${elapsed}s)" >&2
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "SSH port for pod ${pod_id} did not appear within ${max_wait}s." >&2
    return 1
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

# Parse pod ID from "pod "abc123xyz" created" output
parse_pod_id() {
    grep -oP 'pod "\K[^"]+' || true
}

# Wait until a pod reaches a given status (default: RUNNING)
wait_for_pod() {
    local pod_id="$1"
    local target_status="${2:-RUNNING}"
    local max_wait=300 elapsed=0
    log_info "Waiting for pod ${pod_id} to reach ${target_status}..."
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(pod_status "$pod_id")
        if [[ "$status" == "$target_status" ]]; then
            log_ok "Pod ${pod_id} is ${target_status}."
            return 0
        fi
        log_info "  Pod ${pod_id} status: ${status:-unknown} (${elapsed}s elapsed, waiting for ${target_status})..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_warn "Pod ${pod_id} did not reach ${target_status} within ${max_wait}s."
    return 1
}

# Run a script on a pod via SSH
run_remote() {
    local pod_id="$1"
    local script="$2"
    local log_ssh_command="${3:-yes}"
    local ssh_info host port
    ssh_info=$(pod_ssh_details "$pod_id")
    if [[ -z "$ssh_info" ]]; then
        log_error "Could not determine SSH details for pod ${pod_id}."
        return 1
    fi
    host=$(echo "$ssh_info" | awk '{print $1}')
    port=$(echo "$ssh_info" | awk '{print $2}')
    if [[ "$log_ssh_command" == "yes" ]]; then
        log_info "SSH: ssh root@${host} -p ${port} -i ${SSH_KEY}"
    fi
    # Retry until SSH daemon accepts connections (port visible != daemon ready)
    local max_wait=60 elapsed=0
    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$SSH_KEY" -p "$port" "root@${host}" true < /dev/null 2> /dev/null; do
        if [[ $elapsed -ge $max_wait ]]; then
            log_error "SSH daemon on ${host}:${port} not ready after ${max_wait}s."
            return 1
        fi
        log_info "Waiting for SSH daemon on ${host}:${port}... (${elapsed}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        -i "$SSH_KEY" \
        -p "$port" \
        "root@${host}" \
        "bash -s" <<< "$script"
}

# Build install script: install LM Studio and start the server (no model download)
build_install_script() {
    cat << 'INSTALL_EOF'
set -e
LMS_BIN="/root/.lmstudio/bin/lms"
INVALID_PASSKEY_PATTERN='Invalid passkey for lms CLI client'
AUTOSTART_SCRIPT='/usr/local/bin/runpod-lmstudio-autostart.sh'
DEPLOYMENT_ENV='/root/.config/runpod-lmstudio-deployment.env'

ensure_lmstudio_path() {
    export PATH="/root/.lmstudio/bin:$PATH"
    grep -qxF 'export PATH="/root/.lmstudio/bin:$PATH"' /root/.bashrc || echo 'export PATH="/root/.lmstudio/bin:$PATH"' >> /root/.bashrc
}

install_lmstudio() {
    if [[ -x "${LMS_BIN}" ]]; then
        echo "[SETUP] LM Studio already installed."
        ensure_lmstudio_path
        return 0
    fi
    echo "[SETUP] Installing LM Studio..."
    curl -fsSL https://lmstudio.ai/install.sh | bash
    ensure_lmstudio_path
}

write_autostart_script() {
    mkdir -p "$(dirname "${DEPLOYMENT_ENV}")"
    cat > "${AUTOSTART_SCRIPT}" <<'AUTOSTART_EOF'
#!/usr/bin/env bash

set -euo pipefail

LMS_BIN="/root/.lmstudio/bin/lms"
DEPLOYMENT_ENV='/root/.config/runpod-lmstudio-deployment.env'

ensure_lmstudio_path() {
    export PATH="/root/.lmstudio/bin:$PATH"
}

wait_for_lmstudio_cli() {
    local attempts=0
    while [[ ${attempts} -lt 30 ]]; do
        if "${LMS_BIN}" status >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_lmstudio_runtime() {
    local attempts=0
    while [[ ${attempts} -lt 30 ]]; do
        if "${LMS_BIN}" runtime ls >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_lmstudio_server() {
    local attempts=0
    while [[ ${attempts} -lt 60 ]]; do
        if curl -sf http://127.0.0.1:1234/api/v0/models >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

resolve_cuda_runtime() {
    "${LMS_BIN}" runtime ls 2>/dev/null | awk '/nvidia-cuda/ {print $1}' | sort -V | tail -1
}

resolve_model_id() {
    local filename="$1"
    local max_attempts=30 attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local result
        result=$("${LMS_BIN}" ls 2>/dev/null | awk 'NR>1 && NF>0 {print $1}' | python3 -c '
import re
import sys

def normalize(value):
    value = value.strip().lower()
    value = value.split("/")[-1]
    value = re.sub(r"\.gguf$", "", value)
    value = re.sub(r"-gguf$", "", value)
    value = re.sub(r"[^a-z0-9]", "", value)
    return value

needle = normalize(sys.argv[1])
lines = [line.strip() for line in sys.stdin if line.strip()]
scored_matches = []
for line in lines:
    normalized_line = normalize(line)
    if normalized_line == "":
        continue
    if normalized_line in needle or needle in normalized_line:
        scored_matches.append((line, len(normalized_line)))

if not scored_matches:
    raise SystemExit(1)

print(max(scored_matches, key=lambda item: item[1])[0])
' "${filename}" 2>/dev/null || true)
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "[STARTUP] Waiting for LM Studio to index model... (${attempt}/${max_attempts})"
        sleep 5
    done
    return 1
}

is_model_loaded() {
    local model_id="$1"
    curl -sf http://127.0.0.1:1234/api/v0/models | python3 -c '
import json
import sys

data = json.load(sys.stdin).get("data", [])
model_id = sys.argv[1]
print("yes" if any(model.get("id", "") == model_id and model.get("state") == "loaded" for model in data) else "no")
' "${model_id}" 2>/dev/null || echo 'no'
}

wait_for_loaded_model() {
    local model_id="$1"
    local attempts=0
    while [[ ${attempts} -lt 30 ]]; do
        if "${LMS_BIN}" ps 2>/dev/null | awk -v id="${model_id}" '$1 == id { found = 1 } END { exit(found ? 0 : 1) }'; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

download_model_if_needed() {
    local model="$1"
    local url="$2"
    local filename="$3"

    mkdir -p "$HOME/.lmstudio/models/${model}"
    if [[ -f "$HOME/.lmstudio/models/${model}/${filename}" ]]; then
        echo "[STARTUP] Model already downloaded: ${filename}"
        return 0
    fi

    echo "[STARTUP] Downloading model: ${filename}"
    if command -v aria2c >/dev/null 2>&1 || apt-get install -y -qq aria2 >/dev/null 2>&1; then
        aria2c -x 16 -s 16 --file-allocation=none \
            --console-log-level=notice --summary-interval=5 \
            -d "$HOME/.lmstudio/models/${model}" -o "${filename}" "${url}"
    else
        curl -L --progress-bar -C - -o "$HOME/.lmstudio/models/${model}/${filename}" "${url}"
    fi
    echo "[STARTUP] Download complete."
    sleep 10
}

start_lmstudio_stack() {
    local cuda_runtime

    ensure_lmstudio_path

    if curl -sf http://127.0.0.1:1234/api/v0/models >/dev/null 2>&1; then
        echo "[STARTUP] LM Studio server already reachable on port 1234."
        return 0
    fi

    echo "[STARTUP] Starting LM Studio daemon..."
    "${LMS_BIN}" daemon up >/var/log/lmstudio-daemon.log 2>&1 || true
    wait_for_lmstudio_cli
    wait_for_lmstudio_runtime

    cuda_runtime=$(resolve_cuda_runtime)
    if [[ -n "${cuda_runtime}" ]]; then
        "${LMS_BIN}" runtime select "${cuda_runtime}" >/dev/null 2>&1 || true
    fi

    echo "[STARTUP] Starting LM Studio server on port 1234..."
    "${LMS_BIN}" server start --port 1234 --bind 0.0.0.0 >/var/log/lmstudio.log 2>&1 || true
    wait_for_lmstudio_server
}

load_configured_model() {
    local filename
    local model_id
    local load_args=()

    if [[ ! -f "${DEPLOYMENT_ENV}" ]]; then
        echo "[STARTUP] No deployment config found."
        return 0
    fi

    # shellcheck source=/dev/null
    source "${DEPLOYMENT_ENV}"

    if [[ -z "${MODEL_ID:-}" || -z "${MODEL_URL:-}" ]]; then
        echo "[STARTUP] Deployment config is incomplete."
        return 0
    fi

    filename=$(basename "${MODEL_URL}")
    download_model_if_needed "${MODEL_ID}" "${MODEL_URL}" "${filename}"

    echo "[STARTUP] Resolving model identifier..."
    model_id=$(resolve_model_id "${filename}")
    echo "[STARTUP] Resolved model identifier: ${model_id}"

    if [[ "$(is_model_loaded "${model_id}")" == 'yes' ]]; then
        echo "[STARTUP] Model already loaded: ${model_id}"
        return 0
    fi

    load_args=("${model_id}")
    if [[ -n "${MODEL_CONTEXT_LENGTH:-}" ]]; then
        load_args+=(--context-length "${MODEL_CONTEXT_LENGTH}")
    fi

    echo "[STARTUP] Loading model..."
    "${LMS_BIN}" load "${load_args[@]}" < /dev/null >/tmp/lmstudio-load.log 2>&1 || {
        cat /tmp/lmstudio-load.log
        exit 1
    }

    if ! wait_for_loaded_model "${model_id}"; then
        echo "[STARTUP] Model failed to appear in lms ps output."
        exit 1
    fi

    echo "[STARTUP] Model loaded successfully."
}

start_idle_watcher() {
    local idle_seconds

    if [[ ! -f "${DEPLOYMENT_ENV}" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "${DEPLOYMENT_ENV}"
    idle_seconds="${AUTO_DESTROY_ON_IDLE:-0}"

    if [[ "${idle_seconds}" -le 0 ]]; then
        return 0
    fi

    # Kill any previously running watcher before starting a fresh one.
    pkill -f runpod-lmstudio-idle-watcher 2>/dev/null || true
    sleep 1

    nohup /usr/local/bin/runpod-lmstudio-idle-watcher.sh \
        > /var/log/runpod-idle-watcher.log 2>&1 &
    echo "[STARTUP] Idle watcher started (destroys pod after ${idle_seconds}s of idle)."
}

main() {
    start_lmstudio_stack
    load_configured_model
    start_idle_watcher
}

main "$@"
AUTOSTART_EOF
    chmod +x "${AUTOSTART_SCRIPT}"

    # Write idle watcher script (reads config from deployment env at runtime).
    cat > /usr/local/bin/runpod-lmstudio-idle-watcher.sh <<'IDLE_WATCHER_EOF'
#!/usr/bin/env bash
DEPLOYMENT_ENV='/root/.config/runpod-lmstudio-deployment.env'

if [[ ! -f "${DEPLOYMENT_ENV}" ]]; then
    echo "[IDLE] No deployment env found, exiting."
    exit 0
fi

# shellcheck source=/dev/null
source "${DEPLOYMENT_ENV}"

AUTO_DESTROY_SECONDS="${AUTO_DESTROY_ON_IDLE:-0}"
if [[ "${AUTO_DESTROY_SECONDS}" -le 0 ]]; then
    exit 0
fi

RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
POD_ID="${RUNPOD_POD_ID:-}"

if [[ -z "${RUNPOD_API_KEY}" ]]; then
    echo "[IDLE] RUNPOD_API_KEY not set, idle watcher disabled."
    exit 1
fi
if [[ -z "${POD_ID}" ]]; then
    echo "[IDLE] RUNPOD_POD_ID env var not available, idle watcher disabled."
    exit 1
fi

echo "[IDLE] Watcher started. Pod ${POD_ID} will be destroyed after ${AUTO_DESTROY_SECONDS}s of idle."
idle_since=$(date +%s)

is_idle() {
    local models_json
    models_json=$(curl -sf http://127.0.0.1:1234/api/v0/models 2>/dev/null) || return 1

    # Not idle if any model is still loading or unloading.
    if echo "${models_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', [])
sys.exit(0 if any(m.get('state') in ('loading', 'unloading') for m in data) else 1)
" 2>/dev/null; then
        return 1
    fi

    # Not idle if any non-loopback client is connected to port 1234.
    local conn_count
    conn_count=$(ss -tn state established '( sport = :1234 )' 2>/dev/null \
        | grep -v '127\.0\.0\.1' | tail -n +2 | wc -l) || conn_count=0
    [[ "${conn_count}" -eq 0 ]]
}

destroy_pod() {
    echo "[IDLE] Terminating pod ${POD_ID} via RunPod API..."
    curl -sSL -X POST \
        "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"query\": \"mutation { podTerminate(input: { podId: \\\"${POD_ID}\\\" }) }\"}"
    echo
}

while true; do
    sleep 30
    if is_idle; then
        now=$(date +%s)
        elapsed=$(( now - idle_since ))
        echo "[IDLE] Idle for ${elapsed}s / ${AUTO_DESTROY_SECONDS}s"
        if [[ "${elapsed}" -ge "${AUTO_DESTROY_SECONDS}" ]]; then
            destroy_pod
            exit 0
        fi
    else
        idle_since=$(date +%s)
    fi
done
IDLE_WATCHER_EOF
    chmod +x /usr/local/bin/runpod-lmstudio-idle-watcher.sh
}

log_contains_invalid_passkey() {
    local log_file="$1"
    [[ -f "${log_file}" ]] && grep -qi "${INVALID_PASSKEY_PATTERN}" "${log_file}"
}

run_lmstudio_probe() {
    local output_file
    output_file=$(mktemp)
    if "$@" >"${output_file}" 2>&1; then
        rm -f "${output_file}"
        return 0
    fi
    if grep -qi "${INVALID_PASSKEY_PATTERN}" "${output_file}"; then
        rm -f "${output_file}"
        return 42
    fi
    rm -f "${output_file}"
    return 1
}

run_lmstudio_capture() {
    local output_file
    local status
    output_file=$(mktemp)
    if "$@" >"${output_file}" 2>&1; then
        cat "${output_file}"
        rm -f "${output_file}"
        return 0
    fi
    status=$?
    cat "${output_file}"
    if grep -qi "${INVALID_PASSKEY_PATTERN}" "${output_file}"; then
        rm -f "${output_file}"
        return 42
    fi
    rm -f "${output_file}"
    return "${status}"
}

reset_lmstudio_processes() {
    "${LMS_BIN}" daemon down >/dev/null 2>&1 || true
    pkill -f '/root/.lmstudio/llmster' 2>/dev/null || true
    pkill -f '/root/.lmstudio/bin/lms daemon up' 2>/dev/null || true
    sleep 2
}

repair_invalid_passkey_state() {
    local backup_dir
    backup_dir=$(mktemp -d)

    echo "[WARN] Invalid passkey detected. Resetting LM Studio state and retrying once..."
    reset_lmstudio_processes

    if [[ -d "/root/.lmstudio/models" ]]; then
        mkdir -p "${backup_dir}"
        mv "/root/.lmstudio/models" "${backup_dir}/models"
    fi

    rm -rf /root/.lmstudio
    mkdir -p /root/.lmstudio

    if [[ -d "${backup_dir}/models" ]]; then
        mv "${backup_dir}/models" /root/.lmstudio/models
    fi

    rm -rf "${backup_dir}"
    install_lmstudio
}

wait_for_lmstudio_cli() {
    local attempts=0
    local probe_status=0
    while [[ ${attempts} -lt 30 ]]; do
        if run_lmstudio_probe "${LMS_BIN}" status; then
            return 0
        fi
        probe_status=$?
        if [[ ${probe_status} -eq 42 ]]; then
            return 42
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_lmstudio_runtime() {
    local attempts=0
    local probe_status=0
    while [[ ${attempts} -lt 30 ]]; do
        if run_lmstudio_probe "${LMS_BIN}" runtime ls; then
            return 0
        fi
        probe_status=$?
        if [[ ${probe_status} -eq 42 ]]; then
            return 42
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_lmstudio_server() {
    local attempts=0
    while [[ ${attempts} -lt 30 ]]; do
        if curl -sf http://127.0.0.1:1234/api/v0/models >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

resolve_cuda_runtime() {
    "${LMS_BIN}" runtime ls 2>/dev/null | awk '/nvidia-cuda/ {print $1}' | sort -V | tail -1
}

run_lmstudio_runtime_command() {
    local output_file
    local attempt
    local saw_invalid_passkey=0
    output_file=$(mktemp)
    for attempt in 1 2 3 4 5; do
        if "$@" >"${output_file}" 2>&1; then
            cat "${output_file}"
            rm -f "${output_file}"
            return 0
        fi
        if grep -qi "${INVALID_PASSKEY_PATTERN}" "${output_file}"; then
            saw_invalid_passkey=1
            sleep 2
            continue
        fi
        if grep -qi 'WebSocket connection closed' "${output_file}"; then
            sleep 2
            continue
        fi
        cat "${output_file}"
        rm -f "${output_file}"
        return 1
    done
    cat "${output_file}"
    rm -f "${output_file}"
    if [[ ${saw_invalid_passkey} -eq 1 ]]; then
        return 42
    fi
    return 1
}

start_lmstudio_stack() {
    local status
    local runtime_status=0

    echo "[SETUP] Resetting LM Studio daemon state..."
    reset_lmstudio_processes

    echo "[SETUP] Starting LM Studio daemon..."
    if run_lmstudio_capture "${LMS_BIN}" daemon up > /var/log/lmstudio-daemon.log 2>&1; then
        :
    else
        status=$?
        echo "[ERROR] LM Studio daemon failed to start."
        cat /var/log/lmstudio-daemon.log || true
        return "${status}"
    fi

    if wait_for_lmstudio_cli; then
        echo "[SETUP] LM Studio daemon is ready."
    else
        status=$?
        echo "[ERROR] LM Studio daemon did not become ready."
        cat /var/log/lmstudio-daemon.log || true
        return "${status}"
    fi

    if wait_for_lmstudio_runtime; then
        echo "[SETUP] LM Studio runtime client is ready."
    else
        status=$?
        echo "[ERROR] LM Studio runtime client did not become ready."
        cat /var/log/lmstudio-daemon.log || true
        return "${status}"
    fi

    echo "[SETUP] Installing CUDA runtime for LM Studio..."
    CUDA_RUNTIME=$(resolve_cuda_runtime)
    if [[ -n "$CUDA_RUNTIME" ]]; then
        echo "[SETUP] CUDA runtime already available: $CUDA_RUNTIME"
    else
        if run_lmstudio_runtime_command "${LMS_BIN}" runtime get llama.cpp-linux-x86_64-nvidia-cuda12-avx2 --allow-incompatible; then
            :
        else
            runtime_status=$?
            if [[ ${runtime_status} -eq 42 ]]; then
                echo "[ERROR] Invalid passkey while downloading CUDA runtime."
                return 42
            fi
            echo "[WARN] Could not download CUDA runtime."
        fi
        sleep 3
        CUDA_RUNTIME=$(resolve_cuda_runtime)
    fi

    if [[ -n "$CUDA_RUNTIME" ]]; then
        if run_lmstudio_runtime_command "${LMS_BIN}" runtime select "$CUDA_RUNTIME"; then
            echo "[SETUP] CUDA runtime selected: $CUDA_RUNTIME"
        else
            runtime_status=$?
            if [[ ${runtime_status} -eq 42 ]]; then
                echo "[ERROR] Invalid passkey while selecting CUDA runtime."
                return 42
            fi
            echo "[WARN] Could not select CUDA runtime."
        fi
    else
        # fallback: try selecting by known name pattern directly
        if run_lmstudio_runtime_command "${LMS_BIN}" runtime select llama.cpp-linux-x86_64-nvidia-cuda12-avx2; then
            echo "[SETUP] CUDA runtime selected (fallback)."
        else
            runtime_status=$?
            if [[ ${runtime_status} -eq 42 ]]; then
                echo "[ERROR] Invalid passkey while selecting fallback CUDA runtime."
                return 42
            fi
            echo "[WARN] Could not select CUDA runtime."
        fi
    fi

    echo "[SETUP] Starting LM Studio server on port 1234..."
    if run_lmstudio_capture "${LMS_BIN}" server start --port 1234 --bind 0.0.0.0 > /var/log/lmstudio.log 2>&1; then
        :
    else
        status=$?
        echo "[ERROR] LM Studio server failed to start."
        echo "[SETUP] LM Studio daemon log:"
        cat /var/log/lmstudio-daemon.log || true
        echo "[SETUP] LM Studio server log:"
        cat /var/log/lmstudio.log || true
        return "${status}"
    fi

    if ! wait_for_lmstudio_server; then
        echo "[ERROR] LM Studio server did not become reachable on port 1234."
        echo "[SETUP] LM Studio daemon log:"
        cat /var/log/lmstudio-daemon.log || true
        echo "[SETUP] LM Studio server log:"
        cat /var/log/lmstudio.log || true
        if log_contains_invalid_passkey /var/log/lmstudio-daemon.log || log_contains_invalid_passkey /var/log/lmstudio.log; then
            return 42
        fi
        return 1
    fi

    echo "[SETUP] LM Studio server log:"
    cat /var/log/lmstudio.log
}

install_lmstudio

for install_attempt in 1 2; do
    if start_lmstudio_stack; then
        break
    else
        install_status=$?
    fi
    if [[ ${install_status} -ne 42 || ${install_attempt} -ge 2 ]]; then
        exit "${install_status}"
    fi

    repair_invalid_passkey_state
done

echo "[SETUP] Enabling justInTimeModelLoading..."
python3 -c "
import json
import os
path = '/root/.lmstudio/.internal/http-server-config.json'
if not os.path.exists(path):
    raise SystemExit(0)
with open(path) as f:
    cfg = json.load(f)
cfg['justInTimeModelLoading'] = True
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
"
write_autostart_script
echo "[SETUP] LM Studio server started, log: /var/log/lmstudio.log"
INSTALL_EOF
}

# Build load script: download the model for a single pod, then load into memory
build_load_script() {
    local model="$1"
    local url="$2"
    local context_length="${3:-}"
    local auto_destroy_on_idle="${4:-}"
    local api_key="${5:-}"
    local pod_id="${6:-}"
    cat << LOAD_EOF
set -e
mkdir -p /root/.config
cat > /root/.config/runpod-lmstudio-deployment.env <<'ENV_EOF'
MODEL_ID="${model}"
MODEL_URL="${url}"
MODEL_CONTEXT_LENGTH="${context_length}"
AUTO_DESTROY_ON_IDLE="${auto_destroy_on_idle}"
RUNPOD_API_KEY="${api_key}"
RUNPOD_POD_ID="${pod_id}"
ENV_EOF

if [[ ! -x /usr/local/bin/runpod-lmstudio-autostart.sh ]]; then
    echo "[ERROR] Autostart script not found. Run the install step first."
    exit 1
fi

/usr/local/bin/runpod-lmstudio-autostart.sh
LOAD_EOF
}

load_configured_deployments() {
    local pods_json="${1:-}"
    local count
    local deployment_count

    if [[ -z "$pods_json" ]]; then
        pods_json=$(our_pods_json) || pods_json='[]'
    fi

    count=$(echo "$pods_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        log_error "No running pods found. Run './runpod.sh create' first."
        return 1
    fi

    deployment_count=$(echo "$CONFIG_JSON" | jq '(.pods // []) | length')
    if [[ "$deployment_count" -eq 0 ]]; then
        log_error "No pod configured. Run './runpod.sh create --id ... --gpu ... --hdd ... --model ... --context-length ...' first."
        return 1
    fi

    log_info "Loading ${deployment_count} deployment(s) onto ${count} running pod(s)..."

    local i
    for ((i = 0; i < deployment_count; i++)); do
        local model_id url name pod_config_id pod_id context_length
        pod_config_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].id // \"\"")
        model_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].model // \"\"")
        url=$(model_url_from_pod_config_id "$pod_config_id")
        name=$(pod_name_from_config_id "$pod_config_id")

        pod_id=$(echo "$pods_json" | jq -r --arg n "$name" 'first(.[] | select(.name == $n and .desiredStatus == "RUNNING") | .id) // ""')
        if [[ -z "$pod_id" ]]; then
            log_error "No running pod found for '${name}'."
            return 1
        fi
        if [[ -z "$url" ]]; then
            log_error "No model URL configured for '${model_id}'."
            return 1
        fi

        context_length=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].context_length // \"\"")
        local auto_destroy_on_idle
        auto_destroy_on_idle=$(echo "$CONFIG_JSON" | jq -r --arg pid "$pod_config_id" \
            'first((.pods // [])[] | select((.id | tostring) == $pid) | .auto_destroy_on_idle) // ""')
        log_info "Preparing model '${model_id}' on ${name} (${pod_id})..."
        local load_script
        load_script=$(build_load_script "$model_id" "$url" "$context_length" "$auto_destroy_on_idle" "$RUNPOD_API_KEY" "$pod_id")
        run_remote "$pod_id" "$load_script" || {
            log_error "Model preparation failed for ${name} (${pod_id})."
            return 1
        }
        log_ok "Model loaded on ${name}."
    done

    echo ""
    log_ok "All models loaded."
}

ensure_bootstrap_on_running_pods() {
    local pods_json="$1"
    local install_script
    install_script=$(build_install_script)

    while read -r pod; do
        local pod_id pod_name pod_status_val bootstrap_status
        pod_id=$(echo "$pod" | jq -r '.id')
        pod_name=$(echo "$pod" | jq -r '.name')
        pod_status_val=$(echo "$pod" | jq -r '.desiredStatus')

        if [[ "$pod_status_val" != "RUNNING" ]]; then
            continue
        fi

        bootstrap_status=$(run_remote "$pod_id" 'if [[ -x /usr/local/bin/runpod-lmstudio-autostart.sh ]]; then echo ready; else echo missing; fi' 'no' 2> /dev/null || echo 'missing')

        if [[ "$bootstrap_status" == *"ready"* ]]; then
            log_info "Ensuring LM Studio autostart on ${pod_name} (${pod_id})..."
            run_remote "$pod_id" '/usr/local/bin/runpod-lmstudio-autostart.sh' 'no' || {
                log_error "LM Studio autostart failed on ${pod_name} (${pod_id})."
                return 1
            }
            log_ok "LM Studio autostart verified on ${pod_name}."
            continue
        fi

        log_info "Installing LM Studio bootstrap on ${pod_name} (${pod_id})..."
        run_remote "$pod_id" "$install_script" || {
            log_error "Bootstrap install failed on ${pod_name} (${pod_id})."
            return 1
        }
        log_ok "Bootstrap installed on ${pod_name}."
    done < <(echo "$pods_json" | jq -c '.[]')
}

# -------------------------------------------------------------------
# pod create helper — uses RunPod GraphQL API (podFindAndDeployOnDemand) directly.
# The GraphQL API searches the full pool like the GUI (no machine pinning).
# Retries up to 10 times with short fixed delay.
# Prints pod_id to stdout; all log output to stderr.
# -------------------------------------------------------------------
_create_pod_with_fallback() {
    local name="$1" gpu="$2" hdd="$3"

    # build JSON payload via python3 to handle all escaping correctly
    local payload
    payload=$(python3 -c "
import json, sys
name        = sys.argv[1]
gpu         = sys.argv[2]
hdd         = int(sys.argv[3])
image       = sys.argv[4]
docker_args = sys.argv[5]
pubkey      = sys.argv[6]

mutation = '''
mutation {
  podFindAndDeployOnDemand(input: {
    cloudType: SECURE,
    gpuCount: 1,
    gpuTypeId: ''' + json.dumps(gpu) + ''',
    name: ''' + json.dumps(name) + ''',
    imageName: ''' + json.dumps(image) + ''',
    containerDiskInGb: ''' + str(hdd) + ''',
    volumeInGb: 0,
    minVcpuCount: 2,
    minMemoryInGb: 15,
    ports: \"22/tcp,1234/http\",
    dockerArgs: ''' + json.dumps(docker_args) + ''',
    env: [{key: \"MY_SSH_PUBLIC_KEY\", value: ''' + json.dumps(pubkey) + '''}]
  }) {
    id
    machineId
  }
}
'''
print(json.dumps({'query': mutation}))
" "$name" "$gpu" "$hdd" "$IMAGE" "$SSH_DAEMON_ARGS" "$SSH_PUBKEY")

    local max_attempts=10 attempt
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        log_info "  Attempt ${attempt}/${max_attempts}: calling RunPod GraphQL API..." >&2
        local response pod_id err_msg
        response=$(runpod_api "$payload" 2>&1) || true
        pod_id=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['podFindAndDeployOnDemand']['id'])
except Exception:
    pass
" 2> /dev/null || true)
        if [[ -n "$pod_id" ]]; then
            echo "$pod_id"
            return 0
        fi
        err_msg=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    errs = d.get('errors', [])
    print(errs[0]['message'] if errs else 'unknown error')
except Exception:
    print(sys.stdin.read()[:200])
" 2> /dev/null || echo "unknown error")
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Attempt ${attempt}/${max_attempts} failed: ${err_msg}" >&2
            log_info "Retrying in 5s..." >&2
            sleep 5
        else
            log_error "All ${max_attempts} attempts failed: ${err_msg}" >&2
        fi
    done
    return 1
}

# -------------------------------------------------------------------
# create
# -------------------------------------------------------------------

# Set up Cloudflare redirects: one subdomain per pod (<config_id>.<domain> → pod proxy URL).
# A CNAME to *.proxy.runpod.net always causes Error 1014 because that host is behind
# Cloudflare under RunPod's account. Simple fix: proxied A record (dummy IP) so
# Cloudflare accepts the host, plus a Bulk Redirect that does a 302 to the pod URL.
# The browser follows the redirect and talks directly to RunPod — no proxy magic needed.
set_cloudflare_cnames() {
    local -n _pod_ids=$1
    local -n _pod_config_ids=$2
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"
    local cf_domain="${CLOUDFLARE_DOMAIN:-}"

    if [[ -z "$cf_api_key" || -z "$cf_domain" ]]; then
        log_warn "CLOUDFLARE_API_KEY or CLOUDFLARE_DOMAIN not set, skipping redirect setup."
        return 0
    fi

    # Find Cloudflare zone for the base domain.
    local zone_id='' zone_name=''
    IFS='.' read -ra _parts <<< "$cf_domain"
    local _n=${#_parts[@]}
    for ((_j = 0; _j < _n - 1; _j++)); do
        local _candidate
        _candidate=$(
            IFS='.'
            echo "${_parts[*]:$_j}"
        )
        local _zone_resp
        _zone_resp=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=${_candidate}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        zone_id=$(echo "$_zone_resp" | python3 -c \
            "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$zone_id" ]]; then
            zone_name="$_candidate"
            break
        fi
    done

    if [[ -z "$zone_id" ]]; then
        log_warn "Could not find Cloudflare zone for ${cf_domain}, skipping redirect setup."
        return 0
    fi

    log_info "Cloudflare zone: ${zone_name} (${zone_id})"

    # Derive account ID from the zone record (no Accounts/Read permission needed).
    local account_id
    account_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('account',{}).get('id',''))" 2> /dev/null || true)

    if [[ -z "$account_id" ]]; then
        log_warn "Could not determine Cloudflare account ID, skipping redirect setup."
        return 0
    fi

    # Build subdomains: <formatted_config_id>.<cf_domain> per pod.
    local _count=${#_pod_ids[@]}
    local _redirect_items=''

    local _i
    for ((_i = 0; _i < _count; _i++)); do
        local _pod_id _config_id _subdomain _target _display_config_id
        _pod_id="${_pod_ids[$_i]}"
        _config_id="${_pod_config_ids[$_i]}"
        _display_config_id=$(format_pod_display_id "$_config_id")
        _subdomain="${_display_config_id}.${cf_domain}"
        _target="https://${_pod_id}-1234.proxy.runpod.net"

        # Proxied A record (dummy IP) so Cloudflare accepts the host.
        local _existing_a_id
        _existing_a_id=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${_subdomain}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)

        local _a_payload
        _a_payload="{\"type\":\"A\",\"name\":\"${_subdomain}\",\"content\":\"192.0.2.1\",\"ttl\":1,\"proxied\":true}"

        local _dns_resp _dns_a_errors
        if [[ -n "$_existing_a_id" ]]; then
            _dns_resp=$(curl -sSL -X PUT \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${_existing_a_id}" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' \
                -d "$_a_payload")
        else
            _dns_resp=$(curl -sSL -X POST \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' \
                -d "$_a_payload")
        fi
        _dns_a_errors=$(echo "$_dns_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',[])))" 2> /dev/null || true)
        if echo "$_dns_resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)" 2> /dev/null; then
            log_ok "A record (proxied, dummy IP): ${_subdomain} → 192.0.2.1"
        else
            log_warn "Failed to set A record for ${_subdomain}: ${_dns_a_errors}"
        fi

        # Accumulate redirect entries as newline-separated "subdomain target" pairs.
        _redirect_items+="${_subdomain} ${_target}"$'\n'
    done

    # Create/reuse a Bulk Redirect list named 'runpodhelper'.
    local list_id
    list_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('name')=='runpodhelper']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    if [[ -z "$list_id" ]]; then
        list_id=$(curl -sSL -X POST \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d '{"name":"runpodhelper","kind":"redirect","description":"runpodhelper redirect list"}' \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('id',''))" 2> /dev/null || true)
    fi

    if [[ -z "$list_id" ]]; then
        log_warn "Could not create/find Cloudflare redirect list, skipping."
        return 0
    fi

    # Replace list contents with all current redirect entries.
    local _list_payload
    _list_payload=$(python3 -c "
import json, sys
items = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(' ', 1)
    if len(parts) == 2:
        items.append({
            'redirect': {
                'source_url': 'https://' + parts[0] + '/',
                'target_url': parts[1],
                'status_code': 307,
                'include_subdomains': False,
                'subpath_matching': True,
                'preserve_path_suffix': True,
                'preserve_query_string': True
            }
        })
print(json.dumps(items))
" <<< "$_redirect_items")

    local _list_resp _list_errors
    _list_resp=$(curl -sSL -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists/${list_id}/items" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        -d "$_list_payload")
    _list_errors=$(echo "$_list_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',[])))" 2> /dev/null || true)
    if echo "$_list_resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)" 2> /dev/null; then
        log_ok "Redirect list 'runpodhelper' updated with ${_count} item(s)."
    else
        log_warn "Failed to update redirect list items: ${_list_errors}"
    fi

    # Attach list to the account-level Bulk Redirect ruleset (create if missing).
    local ruleset_id
    ruleset_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/rulesets" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('phase')=='http_request_redirect']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    local _ruleset_payload
    _ruleset_payload=$(python3 -c "
import json
print(json.dumps({
    'name': 'runpodhelper redirects',
    'kind': 'root',
    'phase': 'http_request_redirect',
    'rules': [{
        'ref': 'runpodhelper_redirect',
        'action': 'redirect',
        'action_parameters': {'from_list': {'name': 'runpodhelper', 'key': 'http.request.full_uri'}},
        'expression': 'http.request.full_uri in \$runpodhelper',
        'description': 'runpodhelper redirect'
    }]
}))")

    local _resp _success
    if [[ -n "$ruleset_id" ]]; then
        _resp=$(curl -sSL -X PUT \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/rulesets/${ruleset_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d "$_ruleset_payload")
    else
        _resp=$(curl -sSL -X POST \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/rulesets" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d "$_ruleset_payload")
    fi

    _success=$(echo "$_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2> /dev/null || true)
    if [[ "$_success" == 'True' ]]; then
        log_ok "Bulk redirect ruleset active for ${_count} pod(s) under ${cf_domain}"
    else
        local _err
        _err=$(echo "$_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:200])" 2> /dev/null || true)
        log_warn "Failed to set redirect ruleset: ${_err}"
    fi
}

# Remove all Cloudflare A records and redirect list entries created by set_cloudflare_cnames.
clear_cloudflare_redirects() {
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"
    local cf_domain="${CLOUDFLARE_DOMAIN:-}"

    if [[ -z "$cf_api_key" || -z "$cf_domain" ]]; then
        return 0
    fi

    # Resolve zone ID.
    local zone_id=''
    IFS='.' read -ra _parts <<< "$cf_domain"
    local _n=${#_parts[@]}
    for ((_j = 0; _j < _n - 1; _j++)); do
        local _candidate
        _candidate=$(
            IFS='.'
            echo "${_parts[*]:$_j}"
        )
        local _zone_resp
        _zone_resp=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=${_candidate}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        zone_id=$(echo "$_zone_resp" | python3 -c \
            "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$zone_id" ]]; then break; fi
    done

    if [[ -z "$zone_id" ]]; then return 0; fi

    local account_id
    account_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('account',{}).get('id',''))" 2> /dev/null || true)

    if [[ -z "$account_id" ]]; then return 0; fi

    # Delete A records for every configured pod subdomain.
    local pod_count i
    pod_count=$(echo "$CONFIG_JSON" | jq '(.pods // []) | length')
    for ((i = 0; i < pod_count; i++)); do
        local pod_config_id display_id subdomain record_id
        pod_config_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].id // \"\"")
        display_id=$(format_pod_display_id "$pod_config_id")
        subdomain="${display_id}.${cf_domain}"
        record_id=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${subdomain}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$record_id" ]]; then
            curl -sSL -X DELETE \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' > /dev/null
            log_ok "Deleted DNS record: ${subdomain}"
        fi
    done

    # Clear all items from the 'runpodhelper' redirect list.
    local list_id
    list_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('name')=='runpodhelper']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    if [[ -n "$list_id" ]]; then
        # Fetch current item IDs to delete them (PUT with [] is not always accepted; use DELETE items endpoint).
        local items_json item_ids_json
        items_json=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists/${list_id}/items" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        item_ids_json=$(echo "$items_json" | python3 -c \
            "import json,sys; items=json.load(sys.stdin).get('result',[]); print(json.dumps([{'id':x['id']} for x in items]))" 2> /dev/null || echo '[]')
        if [[ "$item_ids_json" != '[]' ]]; then
            curl -sSL -X DELETE \
                "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists/${list_id}/items" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' \
                -d "{\"items\":${item_ids_json}}" > /dev/null
            log_ok "Cleared Cloudflare redirect list 'runpodhelper'."
        fi
    fi
}

# Remove Cloudflare DNS record and redirect list entry for a single pod config ID.
clear_cloudflare_redirect_for_pod() {
    local pod_config_id="$1"
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"
    local cf_domain="${CLOUDFLARE_DOMAIN:-}"

    if [[ -z "$cf_api_key" || -z "$cf_domain" ]]; then
        return 0
    fi

    local display_id subdomain
    display_id=$(format_pod_display_id "$pod_config_id")
    subdomain="${display_id}.${cf_domain}"

    # Resolve zone ID.
    local zone_id=''
    IFS='.' read -ra _parts <<< "$cf_domain"
    local _n=${#_parts[@]}
    for ((_j = 0; _j < _n - 1; _j++)); do
        local _candidate
        _candidate=$(
            IFS='.'
            echo "${_parts[*]:$_j}"
        )
        local _zone_resp
        _zone_resp=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=${_candidate}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        zone_id=$(echo "$_zone_resp" | python3 -c \
            "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$zone_id" ]]; then break; fi
    done

    if [[ -z "$zone_id" ]]; then return 0; fi

    local account_id
    account_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('account',{}).get('id',''))" 2> /dev/null || true)

    if [[ -z "$account_id" ]]; then return 0; fi

    # Delete the DNS A record for this pod's subdomain.
    local record_id
    record_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${subdomain}" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
    if [[ -n "$record_id" ]]; then
        curl -sSL -X DELETE \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' > /dev/null
        log_ok "Deleted DNS record: ${subdomain}"
    fi

    # Remove only this pod's entry from the redirect list.
    local list_id
    list_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('name')=='runpodhelper']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    if [[ -n "$list_id" ]]; then
        local items_json item_ids_json
        items_json=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists/${list_id}/items" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        item_ids_json=$(echo "$items_json" | python3 -c "
import json, sys
needle = 'https://${subdomain}/'
items = json.load(sys.stdin).get('result', [])
ids = [{'id': x['id']} for x in items if x.get('redirect', {}).get('source_url', '').startswith(needle)]
print(json.dumps(ids))
" 2> /dev/null || echo '[]')
        if [[ "$item_ids_json" != '[]' ]]; then
            curl -sSL -X DELETE \
                "https://api.cloudflare.com/client/v4/accounts/${account_id}/rules/lists/${list_id}/items" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' \
                -d "{\"items\":${item_ids_json}}" > /dev/null
            log_ok "Removed Cloudflare redirect entry for ${subdomain}."
        fi
    fi
}

# Check that all GPUs from config are available via the RunPod GraphQL API.
# Aborts if any GPU is not found in the secure-cloud listing.
# Also resolves partial GPU names to the exact gpuTypeId used by the API.
check_gpu_availability() {
    log_info "Checking GPU availability..."
    local response
    response=$(runpod_api '{"query":"{ gpuTypes { id displayName secureCloud } }"}') || {
        log_error "Could not fetch GPU list from RunPod."
        exit 1
    }
    local pod_count all_ok=true
    pod_count=$(echo "$CONFIG_JSON" | jq '(.pods // []) | length')
    local i
    for ((i = 0; i < pod_count; i++)); do
        local gpu resolved_id
        gpu=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].gpu")
        resolved_id=$(echo "$response" | python3 -c "
import json, sys
try:
    types = json.load(sys.stdin).get('data', {}).get('gpuTypes', [])
    needle = sys.argv[1].lower()
    for t in types:
        if t.get('secureCloud') and (needle in t.get('id', '').lower() or needle in t.get('displayName', '').lower()):
            print(t['id'])
            raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    pass
" "$gpu" 2> /dev/null || true)
        if [[ -n "$resolved_id" ]]; then
            log_ok "  GPU available: ${gpu} (id: ${resolved_id})"
            # Rewrite the gpu field in CONFIG_JSON with the resolved exact id
            CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --argjson idx "$i" --arg resolved "$resolved_id" \
                '.pods[$idx].gpu = $resolved')
        else
            log_error "  GPU NOT available: ${gpu}"
            all_ok=false
        fi
    done
    if [[ "$all_ok" == false ]]; then
        echo ""
        log_error "One or more GPUs are unavailable. Aborting."
        log_info "Available secure-cloud GPUs:"
        echo "$response" | python3 -c "
import json, sys
try:
    types = json.load(sys.stdin).get('data', {}).get('gpuTypes', [])
    for t in [x for x in types if x.get('secureCloud')]:
        print('  ' + t.get('displayName', t.get('id', '?')))
except Exception:
    pass" 2> /dev/null || true
        exit 1
    fi
}

parse_create_args() {
    local id="" gpu="" hdd="" model="" context_length="" auto_destroy_on_idle=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)
                id="$2"
                shift 2
                ;;
            --gpu)
                gpu="$2"
                shift 2
                ;;
            --hdd)
                hdd="$2"
                shift 2
                ;;
            --model)
                model="$2"
                shift 2
                ;;
            --context-length)
                context_length="$2"
                shift 2
                ;;
            --auto-destroy-on-idle)
                auto_destroy_on_idle="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for create: $1"
                exit 1
                ;;
        esac
    done
    for arg_spec in "id:--id" "gpu:--gpu" "hdd:--hdd" "model:--model" "context_length:--context-length"; do
        local var flag
        var="${arg_spec%%:*}"
        flag="${arg_spec##*:}"
        if [[ -z "${!var}" ]]; then
            log_error "Missing required argument: ${flag}"
            exit 1
        fi
    done
    local pod_json
    if [[ -n "$auto_destroy_on_idle" ]]; then
        pod_json=$(jq -n \
            --arg id "$id" \
            --arg gpu "$gpu" \
            --argjson hdd "$hdd" \
            --arg model "$model" \
            --argjson context_length "$context_length" \
            --argjson auto_destroy_on_idle "$auto_destroy_on_idle" \
            '{id: $id, gpu: $gpu, hdd: $hdd, model: $model, context_length: $context_length, auto_destroy_on_idle: $auto_destroy_on_idle}')
    else
        pod_json=$(jq -n \
            --arg id "$id" \
            --arg gpu "$gpu" \
            --argjson hdd "$hdd" \
            --arg model "$model" \
            --argjson context_length "$context_length" \
            '{id: $id, gpu: $gpu, hdd: $hdd, model: $model, context_length: $context_length}')
    fi
    CONFIG_JSON=$(echo "$CONFIG_JSON" | jq --argjson pods "[$pod_json]" '. + {pods: $pods}')
}

cmd_create() {
    parse_create_args "$@"
    local existing
    existing=$(our_pods_json | jq -r '.[].name' 2> /dev/null || true)
    if [[ -n "$existing" ]]; then
        log_error "The following pods already exist:"
        echo "$existing" | sed 's/^/  /'
        log_error "Run './runpod.sh delete' first."
        exit 1
    fi

    check_gpu_availability

    local pod_count
    pod_count=$(echo "$CONFIG_JSON" | jq '(.pods // []) | length')
    load_ssh_pubkey

    local max_attempts=3
    local attempt

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if [[ $attempt -gt 1 ]]; then
            log_info "Retry attempt ${attempt}/${max_attempts}..."
        fi

        log_info "Creating ${pod_count} pods from $(basename "$CONFIG")..."

        declare -a pod_ids=()
        declare -a pod_config_ids=()
        local create_failed=0

        # Delete all pods created so far in this attempt
        rollback() {
            log_warn "Rolling back: deleting ${#pod_ids[@]} created pod(s)..."
            for rollback_id in "${pod_ids[@]}"; do
                local rollback_payload
                rollback_payload=$(printf '{"query":"mutation { podTerminate(input: { podId: \\"%s\\" }) }"}' "$rollback_id")
                runpod_api "$rollback_payload" > /dev/null 2>&1 || true
                log_ok "  Rolled back pod ${rollback_id}."
            done
            pod_ids=()
        }

        # --- Step 1: create all pods ---
        local i
        for ((i = 0; i < pod_count; i++)); do
            local name gpu pod_config_id hdd
            pod_config_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].id // \"\"")
            name=$(pod_name_from_config_id "$pod_config_id")
            gpu=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].gpu")
            hdd=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].hdd // 100")

            log_info "Creating pod $((i + 1))/${pod_count}: ${name} | ${gpu} | ${hdd} GB"
            local pod_id
            pod_id=$(_create_pod_with_fallback "$name" "$gpu" "$hdd") || {
                log_error "Pod $((i + 1)) could not be created."
                create_failed=1
                break
            }
            log_ok "Pod $((i + 1)) created: ${pod_id}"
            pod_ids+=("$pod_id")
            pod_config_ids+=("$pod_config_id")
        done

        if [[ $create_failed -eq 1 ]]; then
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed at pod creation."
                exit 1
            fi
        fi

        # --- Step 2: wait for RUNNING ---
        echo ""
        log_info "Waiting for all pods to reach RUNNING..."
        local running_failed=0
        for pod_id in "${pod_ids[@]}"; do
            wait_for_pod "$pod_id" || {
                log_error "Pod ${pod_id} did not reach RUNNING."
                running_failed=1
                break
            }
        done

        if [[ $running_failed -eq 1 ]]; then
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed waiting for RUNNING."
                exit 1
            fi
        fi

        # --- Step 3: check SSH reachability ---
        echo ""
        log_info "Checking SSH reachability..."
        local ssh_failed=0
        for pod_id in "${pod_ids[@]}"; do
            local ssh_info
            ssh_info=$(pod_ssh_details "$pod_id") || {
                log_error "Pod ${pod_id} is not reachable via SSH."
                ssh_failed=1
                break
            }
            local host port
            host=$(echo "$ssh_info" | awk '{print $1}')
            port=$(echo "$ssh_info" | awk '{print $2}')
            log_ok "  Pod ${pod_id}: ssh root@${host} -p ${port}"
        done

        if [[ $ssh_failed -eq 1 ]]; then
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed at SSH reachability."
                exit 1
            fi
        fi

        # --- Step 4: install LM Studio + start server ---
        echo ""
        log_info "Installing LM Studio and starting server on all pods..."
        local install_script
        install_script=$(build_install_script)
        local install_failed=0
        for ((i = 0; i < pod_count; i++)); do
            local name pod_config_id
            pod_config_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].id // \"\"")
            name=$(pod_name_from_config_id "$pod_config_id")
            log_info "Installing on ${name} (${pod_ids[$i]})..."
            run_remote "${pod_ids[$i]}" "$install_script" || {
                log_error "Install failed for ${name} (${pod_ids[$i]})."
                install_failed=1
                break
            }
            log_ok "LM Studio installed and server started on ${name}."
        done

        if [[ $install_failed -eq 1 ]]; then
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed at LM Studio install."
                exit 1
            fi
        fi

        # --- Step 5: configure deployments and load models ---
        echo ""
        log_info "Configuring deployments and loading models on all pods..."
        local running_pods_json
        running_pods_json=$(our_pods_json) || running_pods_json='[]'
        if ! load_configured_deployments "$running_pods_json"; then
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed while loading models."
                exit 1
            fi
        fi

        # --- All steps succeeded ---
        break
    done

    # --- Summary ---
    echo ""
    log_ok "All pods ready. Summary:"
    printf "  %-14s %-30s %-20s %s\n" "Config ID" "Name" "Pod ID" "GPU"
    printf "  %-14s %-30s %-20s %s\n" "---------" "----" "------" "---"
    for ((i = 0; i < pod_count; i++)); do
        local name gpu pod_config_id display_pod_config_id display_name
        pod_config_id=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].id // \"\"")
        name=$(pod_name_from_config_id "$pod_config_id")
        gpu=$(echo "$CONFIG_JSON" | jq -r ".pods[${i}].gpu")
        display_pod_config_id=$(format_pod_display_id "$pod_config_id")
        display_name=$(pod_display_name_from_config_id "$pod_config_id")
        printf "  %-14s %-30s %-20s %s\n" "$display_pod_config_id" "$display_name" "${pod_ids[$i]}" "$gpu"
    done
    echo ""
    log_info "LM Studio endpoint pattern: https://<pod-id>-1234.proxy.runpod.net"
    log_info "Deployments were loaded automatically. Use './runpod.sh load' to reload them if needed."

    # --- Step 6: set Cloudflare CNAME records ---
    echo ""
    log_info "Setting Cloudflare redirect records..."
    set_cloudflare_cnames pod_ids pod_config_ids

    echo ""
}

# -------------------------------------------------------------------
# delete
# -------------------------------------------------------------------
cmd_delete() {
    local delete_mode='' target_id=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                delete_mode='all'
                shift
                ;;
            --id)
                delete_mode='single'
                target_id="${2:-}"
                if [[ -z "$target_id" ]]; then
                    log_error "--id requires a value."
                    exit 1
                fi
                shift 2
                ;;
            *)
                log_error "Unknown argument: $1"
                echo "Usage: $0 delete {--all | --id <id>}"
                exit 1
                ;;
        esac
    done

    if [[ -z "$delete_mode" ]]; then
        log_error "Either --all or --id <id> must be specified."
        echo "Usage: $0 delete {--all | --id <id>}"
        exit 1
    fi

    log_info "Fetching pods..."
    local pods_json count
    pods_json=$(our_pods_json) || pods_json='[]'

    if [[ "$delete_mode" == 'single' ]]; then
        local target_name
        target_name=$(pod_display_name_from_config_id "$target_id")
        pods_json=$(echo "$pods_json" | jq --arg name "$target_name" '[.[] | select(.name == $name)]')
    fi

    count=$(echo "$pods_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        if [[ "$delete_mode" == 'single' ]]; then
            log_warn "No pod found with id '$(format_pod_display_id "$target_id")'. Nothing to delete."
        else
            log_warn "No configured pods found. Nothing to delete."
        fi
        return 0
    fi
    log_info "Found ${count} pod(s) to terminate."
    while read -r pod; do
        local pod_id pod_name
        pod_id=$(echo "$pod" | jq -r '.id')
        pod_name=$(echo "$pod" | jq -r '.name')
        log_info "Terminating pod '${pod_name}' (${pod_id})..."
        local del_payload del_resp
        del_payload=$(printf '{"query":"mutation { podTerminate(input: { podId: \\"%s\\" }) }"}' "$pod_id")
        del_resp=$(runpod_api "$del_payload")
        if echo "$del_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'errors' not in d else 1)" 2> /dev/null; then
            log_ok "Pod '${pod_name}' (${pod_id}) terminated."
        else
            log_warn "Could not terminate '${pod_name}' (${pod_id}). Remove manually."
        fi
    done < <(echo "$pods_json" | jq -c '.[]')

    echo ""
    log_info "Cleaning up Cloudflare DNS records and redirect rules..."
    if [[ "$delete_mode" == 'single' ]]; then
        clear_cloudflare_redirect_for_pod "$target_id"
    else
        clear_cloudflare_redirects
    fi
}

# -------------------------------------------------------------------
# test
# -------------------------------------------------------------------
cmd_test() {
    local run_count=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runs)
                run_count="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for test: $1"
                exit 1
                ;;
        esac
    done
    local pods_json count
    pods_json=$(our_pods_json) || pods_json='[]'
    count=$(echo "$pods_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        log_error "No configured pods found."
        exit 1
    fi

    local timestamp logs_dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    logs_dir="${PROJECT_DIR}/logs/test-${timestamp}"
    mkdir -p "$logs_dir"

    declare -a test_pids=()
    declare -a test_labels=()
    declare -a test_run_logs=()
    declare -a test_call_logs=()

    while IFS= read -r pod_item; do
        local pod_id pod_name pod_config_id display_pod_config_id pod_status_val gpu model_id pod_url run_log_file call_log_file
        pod_id=$(echo "$pod_item" | jq -r '.id')
        pod_name=$(echo "$pod_item" | jq -r '.name')
        pod_config_id=$(pod_config_id_from_name "$pod_name" || echo "$pod_name")
        display_pod_config_id=$(format_pod_display_id "$pod_config_id")
        pod_status_val=$(echo "$pod_item" | jq -r '.desiredStatus')
        gpu=$(echo "$pod_item" | jq -r '.machine.gpuDisplayName // ""')
        echo "Pod ${display_pod_config_id}: Status ${pod_status_val}"

        if [[ "$pod_status_val" != "RUNNING" ]]; then
            continue
        fi

        local cf_domain="${CLOUDFLARE_DOMAIN:-}"
        if [[ -n "$cf_domain" ]]; then
            pod_url="https://${display_pod_config_id}.${cf_domain}"
        else
            pod_url="https://${pod_id}-1234.proxy.runpod.net"
        fi
        model_id=$(curl -sf --max-time 10 "${pod_url}/api/v0/models" 2> /dev/null | python3 -c "
import json, sys
try:
    models = json.load(sys.stdin).get('data', [])
    loaded = [m for m in models if m.get('state') == 'loaded']
    print(loaded[0]['id'] if loaded else '')
except Exception:
    print('')
" 2> /dev/null || echo '')
        run_log_file="${logs_dir}/pod-${pod_config_id}.run.log"
        call_log_file="${logs_dir}/pod-${pod_config_id}.call.log"

        php "${PACKAGE_DIR}/runpod.php" \
            "$run_count" \
            "--pod-url=${pod_url}" \
            "--model-id=${model_id}" \
            "--gpu-name=${gpu}" \
            "--run-log=${run_log_file}" \
            "--call-log=${call_log_file}" \
            "--project-dir=${PROJECT_DIR}" \
            > /dev/null 2>&1 &

        test_pids+=("$!")
        test_labels+=("Pod ${display_pod_config_id}")
        test_run_logs+=("${run_log_file}")
        test_call_logs+=("${call_log_file}")
    done < <(echo "$pods_json" | jq -c '.[]')

    if [[ ${#test_pids[@]} -eq 0 ]]; then
        log_warn "No RUNNING pods available for tests."
        return 0
    fi

    echo ""
    log_info "Parallel tests started. Logs: ${logs_dir}"

    local failed=0
    for i in "${!test_pids[@]}"; do
        if wait "${test_pids[$i]}"; then
            log_ok "${test_labels[$i]} finished."
        else
            log_error "${test_labels[$i]} failed. See ${test_run_logs[$i]} and ${test_call_logs[$i]}."
            failed=1
        fi
    done

    echo ""
    if [[ "$failed" -eq 0 ]]; then
        log_ok "All pod tests finished."
    else
        log_error "One or more pod tests failed."
        exit 1
    fi
}

# -------------------------------------------------------------------
# status
# -------------------------------------------------------------------
cmd_status() {
    log_info "Fetching pods..."
    local pods_json count
    pods_json=$(our_pods_json) || pods_json='[]'
    count=$(echo "$pods_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        log_warn "No configured pods found."
        return 0
    fi

    echo ""
    while read -r pod; do
        local pod_id pod_name pod_status_val config_pod_id
        pod_id=$(echo "$pod" | jq -r '.id')
        pod_name=$(echo "$pod" | jq -r '.name')
        pod_status_val=$(echo "$pod" | jq -r '.desiredStatus')
        config_pod_id=$(pod_config_id_from_name "$pod_name" || true)

        echo -e "${CYAN}=== $(pod_display_name_from_config_id "$config_pod_id") (${pod_id}) ===${NC}"
        echo "  Config ID:  $(format_pod_display_id "$config_pod_id")"

        # --- Pod running? ---
        if [[ "$pod_status_val" == "RUNNING" ]]; then
            log_ok "  Pod:       RUNNING"
        else
            log_warn "  Pod:       ${pod_status_val}"
        fi

        # --- SSH details ---
        local ssh_info host port
        ssh_info=$(pod_ssh_details "$pod_id" 2> /dev/null) || ssh_info=''
        if [[ -n "$ssh_info" ]]; then
            host=$(echo "$ssh_info" | awk '{print $1}')
            port=$(echo "$ssh_info" | awk '{print $2}')
            echo "             ssh root@${host} -p ${port} -i ${SSH_KEY}"
        fi

        # --- LM Studio endpoint reachable externally? ---
        local lmstudio_url="https://${pod_id}-1234.proxy.runpod.net"
        local http_code
        http_code=$(curl -sf --max-time 10 -o /dev/null -w "%{http_code}" "${lmstudio_url}/api/v0/models" 2> /dev/null || echo "000")
        echo "  URL:       ${lmstudio_url}"
        if [[ "$http_code" == "200" ]]; then
            log_ok "  Proxy:     reachable (${lmstudio_url})"
        else
            log_warn "  Proxy:     not reachable (${lmstudio_url}, HTTP ${http_code})"
            log_warn "  Note:      local LM Studio can still be running even if the external proxy is not reachable yet."
        fi

        # --- LM Studio running locally? / model loaded? (via local HTTP API over SSH) ---
        local local_api_output local_api_summary local_api_status loaded_model_id loaded_model_summary
        local_api_output=$(run_remote "$pod_id" 'curl -sf http://127.0.0.1:1234/api/v0/models' 'no' 2> /dev/null || echo '')
        local_api_summary=$(printf '%s' "$local_api_output" | python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if raw == "":
    print("unknown")
    raise SystemExit(0)

try:
    payload = json.loads(raw)
except Exception:
    print("unknown")
    raise SystemExit(0)

models = payload.get("data", [])
loaded_models = [model for model in models if model.get("state") == "loaded"]
if loaded_models:
    model = loaded_models[0]
    print("loaded\t%s\t%s" % (model.get("id", "unknown"), json.dumps(model, ensure_ascii=True, separators=(",", ":"))))
else:
    print("running")
')
        local_api_status=$(printf '%s' "$local_api_summary" | awk -F '\t' 'NR == 1 {print $1}')
        loaded_model_id=$(printf '%s' "$local_api_summary" | awk -F '\t' 'NR == 1 {print $2}')
        loaded_model_summary=$(printf '%s' "$local_api_summary" | awk -F '\t' 'NR == 1 {print $3}')

        if [[ "$local_api_status" == "loaded" ]]; then
            log_ok "  LM Studio: running locally"
            log_ok "  Loaded:    ${loaded_model_id}"
            log_ok "  Model:     ${loaded_model_summary}"
        elif [[ "$local_api_status" == "running" ]]; then
            log_ok "  LM Studio: running locally"
            log_warn "  Loaded:    none"
            log_warn "  Model:     not loaded"
        else
            log_warn "  LM Studio: local status unknown"
            log_warn "  Loaded:    none"
            log_warn "  Model:     unknown"
        fi

        echo ""
    done < <(echo "$pods_json" | jq -c '.[]')
}

# -------------------------------------------------------------------
# init
# -------------------------------------------------------------------

cmd_init() {
    local copied=0

    # Generate SSH key if not present
    if [ ! -f "${HOME}/.ssh/id_ed25519" ]; then
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -t ed25519 -C "runpodhelper" -f "${HOME}/.ssh/id_ed25519" -N ""
        echo "Created SSH key: ~/.ssh/id_ed25519"
    else
        echo "SSH key already exists: ~/.ssh/id_ed25519, skipping"
    fi

    if [ ! -f "${PROJECT_DIR}/.env.example" ]; then
        cp "${PACKAGE_DIR}/.env.example" "${PROJECT_DIR}/.env.example"
        echo "Created .env.example"
        copied=1
    else
        echo ".env.example already exists, skipping"
    fi

    if [ ! -f "${PROJECT_DIR}/models.yaml" ]; then
        cp "${PACKAGE_DIR}/models.yaml" "${PROJECT_DIR}/models.yaml"
        echo "Created models.yaml"
        copied=1
    else
        echo "models.yaml already exists, skipping"
    fi

    if [ ! -f "${PROJECT_DIR}/.env" ] && [ -f "${PROJECT_DIR}/.env.example" ]; then
        cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
        echo "Created .env from .env.example — please fill in your credentials"
    fi

    if [ "$copied" -eq 1 ]; then
        echo ""
        echo "Next steps:"
        echo "  1. Edit .env with your RunPod/Cloudflare credentials"
        echo "  2. Edit models.yaml to configure your models"
    fi
}

# -------------------------------------------------------------------
# Entry point
# -------------------------------------------------------------------
ACTION="${1:-}"

case "$ACTION" in
    init) cmd_init ;;
    create) cmd_create "${@:2}" ;;
    test) cmd_test "${@:2}" ;;
    delete) cmd_delete "${@:2}" ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 {init|create|test|delete|status}"
        echo ""
        echo "  init    Copy .env.example and models.yaml to project root (run once after install)"
        echo "  create --id <id> --gpu <gpu> --hdd <hdd> --model <model> --context-length <n> [--auto-destroy-on-idle <seconds>]"
        echo "         Check GPU availability, create pod, install LM Studio, start server, load model"
        echo "  test [--runs <n>]"
        echo "         Run runpod.php per RUNNING pod in parallel with separate logs"
        echo "  delete {--all | --id <id>}
         Terminate pod(s) and remove Cloudflare DNS/redirect entries"
        echo "  status  Show current pod status"
        echo ""
        exit 1
        ;;
esac
