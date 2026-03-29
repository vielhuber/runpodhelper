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

CREATE_ID=''
CREATE_GPU=''
CREATE_HDD=''
CREATE_MODEL=''
CREATE_CONTEXT_LENGTH=''
CREATE_PARALLEL=''
CREATE_AUTO_DESTROY=''
CREATE_LMSTUDIO_API_KEY=''

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

model_url_from_model_id() {
    local model_id="$1"
    echo "$CONFIG_JSON" | jq -r --arg id "$model_id" 'first((.models // [])[] | select(.id == $id) | .url) // ""'
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

# Returns the LM Studio HTTP base URL (http://IP:port) for TCP port 1234.
# Queries the RunPod API for the public IP and port. $2 = optional max wait seconds (default 0).
pod_lmstudio_url() {
    local pod_id="$1"
    local max_wait="${2:-0}" elapsed=0
    local payload
    payload=$(printf '{"query":"{ pod(input: { podId: \\"%s\\" }) { runtime { ports { ip publicPort privatePort type } } } }"}' "$pod_id")
    while true; do
        local response entry
        response=$(runpod_api "$payload") || response=''
        entry=$(echo "$response" | python3 -c "
import json, sys
try:
    ports = json.load(sys.stdin)['data']['pod']['runtime']['ports'] or []
    for p in ports:
        if str(p.get('privatePort')) == '1234' and p.get('type') == 'tcp' and p.get('ip') and p.get('publicPort'):
            print('http://' + str(p['ip']) + ':' + str(p['publicPort']))
            break
except Exception:
    pass
" 2> /dev/null || true)
        if [[ -n "$entry" ]]; then
            echo "$entry"
            return 0
        fi
        [[ $elapsed -lt $max_wait ]] || break
        log_info "Waiting for LM Studio port on pod ${pod_id}... (${elapsed}s)" >&2
        sleep 5
        elapsed=$((elapsed + 5))
    done
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

pod_lmstudio_api_key_from_pod_id() {
    local pod_id="$1"
    run_remote "$pod_id" 'if [[ -f /root/.config/runpod-lmstudio-deployment.env ]]; then source /root/.config/runpod-lmstudio-deployment.env; printf "%s" "${LMSTUDIO_API_KEY:-}"; fi' 'no' 2> /dev/null || true
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
    if [[ ! -x "${LMS_BIN}" ]]; then
        echo "[SETUP] Installing LM Studio..."
        curl -fsSL https://lmstudio.ai/install.sh | bash
        ensure_lmstudio_path
    else
        echo "[SETUP] LM Studio already installed."
        ensure_lmstudio_path
    fi
    # Start the daemon briefly so it creates settings.json, then stop it again
    local _settings_file="${HOME}/.lmstudio/settings.json"
    if [[ ! -f "${_settings_file}" ]]; then
        echo "[SETUP] Starting daemon briefly to generate settings.json..."
        "${LMS_BIN}" server start --cors 2>/dev/null || true
        local _waited=0
        while [[ ! -f "${_settings_file}" && ${_waited} -lt 30 ]]; do
            sleep 2
            _waited=$((_waited + 2))
        done
        "${LMS_BIN}" server stop 2>/dev/null || true
    fi
    # Apply developer settings: beta update channel + separate reasoning_content in API responses
    if [[ -f "${_settings_file}" ]]; then
        echo "[SETUP] Configuring LM Studio developer settings..."
        python3 -c "
import json
path = '${_settings_file}'
try:
    with open(path, 'r') as f:
        s = json.load(f)
except Exception:
    s = {}
dev = s.setdefault('developer', {})
# Pull beta llmster updates automatically
dev['appUpdateChannel'] = 'beta'
# Separate reasoning_content from content in /v1/chat/completions responses
dev['separateReasoningContent'] = True
with open(path, 'w') as f:
    json.dump(s, f, indent=2)
print('[SETUP] Developer settings applied (beta channel, separateReasoningContent=true).')
"
    else
        echo "[SETUP] WARNING: settings.json not found, skipping developer settings."
    fi
    # Upgrade llmster itself to the latest beta via the official lms CLI route
    # Ensure daemon is fully stopped before updating (update fails if daemon is running)
    echo "[SETUP] Upgrading LM Studio to latest beta..."
    "${LMS_BIN}" daemon down 2>/dev/null || true
    sleep 2
    "${LMS_BIN}" daemon update --channel beta
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
        if curl -sf http://127.0.0.1:1235/api/v0/models >/dev/null 2>&1; then
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
    curl -sf http://127.0.0.1:1235/api/v0/models | python3 -c '
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

    if curl -sf http://127.0.0.1:1235/api/v0/models >/dev/null 2>&1; then
        echo "[STARTUP] LM Studio server already reachable on port 1235."
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

    echo "[STARTUP] Starting LM Studio server on port 1235..."
    "${LMS_BIN}" server start --port 1235 --bind 127.0.0.1 >/var/log/lmstudio.log 2>&1 || true
    wait_for_lmstudio_server
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        echo "[STARTUP] Nginx already installed."
        return 0
    fi
    echo "[STARTUP] Installing Nginx..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
}

configure_nginx_proxy() {
    local key="$1"

    if [[ -z "${key}" ]]; then
        echo "[ERROR] LMSTUDIO_API_KEY missing in deployment config."
        return 1
    fi

    cat > /etc/nginx/sites-available/lmstudio-proxy <<EOF
server {
    listen 1234 default_server;
    listen [::]:1234 default_server;
    server_name _;

    location / {
        if (\$http_authorization !~* "^Bearer[[:space:]]+${key}$") {
            return 401;
        }

        proxy_pass http://127.0.0.1:1235;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/lmstudio-proxy /etc/nginx/sites-enabled/lmstudio-proxy

    # Some RunPod base images ship a minimal nginx.conf without include directives.
    # Ensure our vhost locations are actually loaded.
    if ! grep -q 'include /etc/nginx/conf.d/\*\.conf;' /etc/nginx/nginx.conf || ! grep -q 'include /etc/nginx/sites-enabled/\*;' /etc/nginx/nginx.conf; then
        python3 - <<'PY'
from pathlib import Path

path = Path('/etc/nginx/nginx.conf')
content = path.read_text()
lines = content.splitlines()

conf_include = '    include /etc/nginx/conf.d/*.conf;'
sites_include = '    include /etc/nginx/sites-enabled/*;'

has_conf_include = conf_include in lines
has_sites_include = sites_include in lines

if has_conf_include and has_sites_include:
    raise SystemExit(0)

http_index = None
for index, line in enumerate(lines):
    if line.strip().startswith('http') and '{' in line:
        http_index = index
        break

if http_index is None:
    raise SystemExit(0)

insert_pos = http_index + 1
inserts = []
if not has_conf_include:
    inserts.append(conf_include)
if not has_sites_include:
    inserts.append(sites_include)

if inserts:
    lines[insert_pos:insert_pos] = inserts + ['']
    path.write_text('\n'.join(lines) + '\n')
PY
    fi

    nginx -t

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl restart nginx
        systemctl enable nginx >/dev/null 2>&1 || true
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        service nginx restart >/dev/null 2>&1 || service nginx start >/dev/null 2>&1 || true
    fi

    if pgrep -x nginx >/dev/null 2>&1; then
        nginx -s reload >/dev/null 2>&1 || true
    else
        nginx >/dev/null 2>&1 || true
    fi

    if ! pgrep -x nginx >/dev/null 2>&1; then
        echo "[ERROR] Failed to start nginx."
        return 1
    fi
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

    install_nginx
    configure_nginx_proxy "${LMSTUDIO_API_KEY:-}"

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
    if [[ -n "${MODEL_PARALLEL:-}" ]]; then
        load_args+=(--parallel "${MODEL_PARALLEL}")
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

    # Send a dummy request to warm up the KV cache before the first real request
    echo "[STARTUP] Warming up model (dummy request)..."
    local warmup_response
    warmup_response=$(curl -sf --max-time 120 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${LMSTUDIO_API_KEY:-}" \
        -d "{\"model\":\"${model_id}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
        "http://127.0.0.1:1234/v1/chat/completions" 2>/dev/null || true)
    if [[ -n "$warmup_response" ]]; then
        echo "[STARTUP] Warmup complete."
    else
        echo "[STARTUP] Warmup request did not return a response (non-fatal)."
    fi
}

start_auto_destroy_watcher() {
    local auto_destroy_seconds

    if [[ ! -f "${DEPLOYMENT_ENV}" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "${DEPLOYMENT_ENV}"
    auto_destroy_seconds="${AUTO_DESTROY:-0}"

    if [[ "${auto_destroy_seconds}" -le 0 ]]; then
        return 0
    fi

    # Kill any previously running watcher before starting a fresh one.
    pkill -f runpod-lmstudio-auto-destroy-watcher 2>/dev/null || true
    sleep 1

    nohup /usr/local/bin/runpod-lmstudio-auto-destroy-watcher.sh \
        > /var/log/runpod-auto-destroy-watcher.log 2>&1 &
    echo "[STARTUP] Auto-destroy watcher started (destroys pod after ${auto_destroy_seconds}s)."
}

main() {
    start_lmstudio_stack
    load_configured_model
    start_auto_destroy_watcher
}

main "$@"
AUTOSTART_EOF
    chmod +x "${AUTOSTART_SCRIPT}"

    # Write auto-destroy watcher script (reads config from deployment env at runtime).
    cat > /usr/local/bin/runpod-lmstudio-auto-destroy-watcher.sh <<'AUTO_DESTROY_WATCHER_EOF'
#!/usr/bin/env bash
DEPLOYMENT_ENV='/root/.config/runpod-lmstudio-deployment.env'

if [[ ! -f "${DEPLOYMENT_ENV}" ]]; then
    echo "[DESTROY] No deployment env found, exiting."
    exit 0
fi

# shellcheck source=/dev/null
source "${DEPLOYMENT_ENV}"

AUTO_DESTROY_SECONDS="${AUTO_DESTROY:-0}"
if [[ "${AUTO_DESTROY_SECONDS}" -le 0 ]]; then
    exit 0
fi

RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
POD_ID="${RUNPOD_POD_ID:-}"

if [[ -z "${RUNPOD_API_KEY}" ]]; then
    echo "[DESTROY] RUNPOD_API_KEY not set, auto-destroy watcher disabled."
    exit 1
fi
if [[ -z "${POD_ID}" ]]; then
    echo "[DESTROY] RUNPOD_POD_ID env var not available, auto-destroy watcher disabled."
    exit 1
fi

echo "[DESTROY] Watcher started. Pod ${POD_ID} will be destroyed in ${AUTO_DESTROY_SECONDS}s."

destroy_pod() {
    echo "[DESTROY] Terminating pod ${POD_ID} via RunPod API..."
    curl -sSL -X POST \
        "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"query\": \"mutation { podTerminate(input: { podId: \\\"${POD_ID}\\\" }) }\"}"
    echo
}

sleep "${AUTO_DESTROY_SECONDS}"
destroy_pod
AUTO_DESTROY_WATCHER_EOF
    chmod +x /usr/local/bin/runpod-lmstudio-auto-destroy-watcher.sh
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
        if curl -sf http://127.0.0.1:1235/api/v0/models >/dev/null 2>&1; then
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

# Print a captured lms output file, stripping terminal animation noise:
# - carriage returns (progress bar overwrites) become newlines
# - inline 'cat: write error' messages from llmster's progress display are removed
_print_lmstudio_output() {
    tr '\r' '\n' < "$1" | grep -v 'cat: write error' || true
}

run_lmstudio_runtime_command() {
    local output_file
    local attempt
    local saw_invalid_passkey=0
    output_file=$(mktemp)
    for attempt in 1 2 3 4 5; do
        if "$@" >"${output_file}" 2>&1; then
            _print_lmstudio_output "${output_file}"
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
        _print_lmstudio_output "${output_file}"
        rm -f "${output_file}"
        return 1
    done
    _print_lmstudio_output "${output_file}"
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

    echo "[SETUP] Starting LM Studio server on port 1235..."
    if run_lmstudio_capture "${LMS_BIN}" server start --port 1235 --bind 127.0.0.1 > /var/log/lmstudio.log 2>&1; then
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
        echo "[ERROR] LM Studio server did not become reachable on port 1235."
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

patch_mcp_timeout() {
    echo "[SETUP] Patching MCP SDK timeout to 600000ms..."
    # Ensure daemon is fully stopped — the binary cannot be patched while it is running.
    "${LMS_BIN}" daemon down 2>/dev/null || true
    sleep 1
    local llmster_dir
    llmster_dir=$(find /root/.lmstudio/llmster/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
    if [[ -z "${llmster_dir}" ]]; then
        echo "[SETUP] WARNING: llmster directory not found, skipping MCP timeout patch."
        return 0
    fi
    echo "[SETUP] llmster dir: ${llmster_dir}"

    # Strategy 1: node_modules layout — patch protocol.js directly
    local protocol_js
    protocol_js=$(find "${llmster_dir}" -path "*/modelcontextprotocol/sdk*/shared/protocol.js" 2>/dev/null | head -1)
    if [[ -n "${protocol_js}" ]]; then
        echo "[SETUP] Found MCP SDK protocol.js at ${protocol_js}"
        sed -i 's/exports\.DEFAULT_REQUEST_TIMEOUT_MSEC = 60000;/exports.DEFAULT_REQUEST_TIMEOUT_MSEC = 600000;/' "${protocol_js}"
        echo "[SETUP] MCP timeout patched via node_modules."
        return 0
    fi

    # Strategy 2: bundled .js file containing the unminified constant
    local bundle_file
    bundle_file=$(grep -rl "DEFAULT_REQUEST_TIMEOUT_MSEC = 60000" "${llmster_dir}" --include="*.js" 2>/dev/null | head -1)
    if [[ -n "${bundle_file}" ]]; then
        echo "[SETUP] Found bundled MCP SDK in ${bundle_file}"
        sed -i 's/DEFAULT_REQUEST_TIMEOUT_MSEC = 60000/DEFAULT_REQUEST_TIMEOUT_MSEC = 600000/g' "${bundle_file}"
        echo "[SETUP] MCP timeout patched in bundle."
        return 0
    fi

    # Strategy 3: binary patch — llmster bundles obfuscated JS (not V8 bytecode).
    # The binary uses string-array obfuscation — DEFAULT_REQUEST_TIMEOUT_MSEC and its value
    # 0xea60 (60000) are never adjacent. Instead we use an anchor: the literal string
    # '_requestHandlers' in the Protocol class constructor (not obfuscated) is always within
    # 600 bytes AFTER the property assignment. We scan back for =0xea60, and replace with
    # =600000 (same byte length — safe in-place patch). Fallback: named-constant patterns
    # for future llmster versions that may ship unobfuscated or differently bundled.
    local binary_file
    binary_file=$(find "${llmster_dir}" -name "llmster" -type f 2>/dev/null | head -1)
    if [[ -n "${binary_file}" ]]; then
        echo "[SETUP] Attempting binary patch on ${binary_file}..."
        python3 - "${binary_file}" <<'PYTHON_PATCH_EOF'
import sys, re, os, shutil
binary_path = sys.argv[1]
with open(binary_path, 'rb') as f:
    data = f.read()

patched = False

# --- Strategy A: anchor-based patch (llmster 0.0.8+ obfuscated binary) ---
# _requestHandlers is the only unobfuscated field name in the MCP Protocol constructor.
# It appears within 600 bytes AFTER the DEFAULT_REQUEST_TIMEOUT_MSEC assignment.
# 0xea60 = 60000ms  →  600000 (same 6 bytes, safe same-length patch).
anchor = b"this['_requestHandlers']=new Map"
anchor_pos = data.find(anchor)
if anchor_pos != -1:
    search_start = max(0, anchor_pos - 600)
    matches = list(re.finditer(b'=0xea60,', data[search_start:anchor_pos]))
    if matches:
        val_start = search_start + matches[-1].start() + 1  # skip '='
        if data[val_start:val_start + 6] == b'0xea60':
            patched_data = data[:val_start] + b'600000' + data[val_start + 6:]
            tmp = binary_path + '.patching'
            with open(tmp, 'wb') as f:
                f.write(patched_data)
            shutil.copymode(binary_path, tmp)
            os.rename(tmp, binary_path)
            print(f'[SETUP] Binary patched via _requestHandlers anchor: 0xea60 -> 600000 at offset {val_start}')
            patched = True

# --- Strategy B: already patched (600000 already present at anchor site) ---
if not patched and anchor_pos != -1:
    search_start = max(0, anchor_pos - 600)
    if b'=600000,' in data[search_start:anchor_pos]:
        print('[SETUP] MCP timeout already patched (600000 found at anchor site).')
        patched = True

# --- Strategy C: named-constant patterns for unobfuscated / future bundle formats ---
if not patched:
    # same-length substitutions only
    patterns = [
        (b"'DEFAULT_REQUEST_TIMEOUT_MSEC']=0xea60", b"'DEFAULT_REQUEST_TIMEOUT_MSEC']=600000"),
        (b'DEFAULT_REQUEST_TIMEOUT_MSEC=60000',     b'DEFAULT_REQUEST_TIMEOUT_MSEC=600000'),
        (b'exports.DEFAULT_REQUEST_TIMEOUT_MSEC=6e4',   b'exports.DEFAULT_REQUEST_TIMEOUT_MSEC=3e5'),
        (b'exports.DEFAULT_REQUEST_TIMEOUT_MSEC=60000', b'exports.DEFAULT_REQUEST_TIMEOUT_MSEC=600000'),
        (b'DEFAULT_REQUEST_TIMEOUT_MSEC=6e4',       b'DEFAULT_REQUEST_TIMEOUT_MSEC=3e5'),
    ]
    for old, new in patterns:
        if old in data:
            count = data.count(old)
            patched_data = data.replace(old, new)
            tmp = binary_path + '.patching'
            with open(tmp, 'wb') as f:
                f.write(patched_data)
            shutil.copymode(binary_path, tmp)
            os.rename(tmp, binary_path)
            print(f'[SETUP] Binary patched {count}x: {old.decode("utf-8", errors="replace")} -> {new.decode("utf-8", errors="replace")}')
            patched = True
            break

if not patched:
    # Diagnostic: log context to aid future pattern discovery.
    found_any = False
    for needle in [b'RequestTimeout', b'DEFAULT_REQUEST_TIMEOUT']:
        for m in re.finditer(re.escape(needle), data):
            ctx_bytes = data[max(0, m.start() - 120):m.end() + 60]
            safe = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx_bytes)
            print(f'[SETUP] DIAG @{m.start()} ({needle.decode()}): {safe}')
            found_any = True
    if not found_any:
        for m in re.finditer(rb'(?<=[^a-zA-Z0-9_])6e4(?=[^a-zA-Z0-9_])', data):
            ctx_bytes = data[max(0, m.start() - 80):m.end() + 40]
            safe = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx_bytes)
            print(f'[SETUP] DIAG 6e4 @{m.start()}: {safe}')
    print('[SETUP] WARNING: No patchable MCP timeout pattern found in binary.')
PYTHON_PATCH_EOF
    else
        echo "[SETUP] WARNING: llmster binary not found for patching."
    fi
}

patch_http_request_timeout() {
    echo "[SETUP] Patching Node.js HTTP requestTimeout (300s → 950s)..."
    local llmster_dir
    llmster_dir=$(find /root/.lmstudio/llmster/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
    if [[ -z "${llmster_dir}" ]]; then
        echo "[SETUP] WARNING: llmster directory not found, skipping HTTP timeout patch."
        return 0
    fi
    local binary_file
    binary_file=$(find "${llmster_dir}" -name "llmster" -type f 2>/dev/null | head -1)
    if [[ -z "${binary_file}" ]]; then
        echo "[SETUP] WARNING: llmster binary not found for HTTP timeout patch."
        return 0
    fi
    # Global replace 0x493e0 (300000ms = 5min) → 0xe7ef0 (950000ms ≈ 16min).
    # Affects: HTTP requestTimeout, DNS cache TTL, npm timeouts — all safe to increase.
    python3 - "${binary_file}" <<'PYTHON_HTTP_PATCH_EOF'
import sys, os, shutil
binary_path = sys.argv[1]
with open(binary_path, 'rb') as f:
    data = f.read()
old = b'0x493e0'
new = b'0xe7ef0'
count = data.count(old)
if count == 0:
    # check if already patched
    if data.count(new) > 0:
        print(f'[SETUP] HTTP requestTimeout already patched ({new.decode()} found).')
    else:
        print('[SETUP] WARNING: 0x493e0 not found in binary.')
    sys.exit(0)
patched = data.replace(old, new)
tmp = binary_path + '.patching'
with open(tmp, 'wb') as f:
    f.write(patched)
shutil.copymode(binary_path, tmp)
os.rename(tmp, binary_path)
print(f'[SETUP] HTTP requestTimeout patched: {old.decode()} → {new.decode()} ({count}x)')
PYTHON_HTTP_PATCH_EOF
}

install_lmstudio
patch_mcp_timeout
patch_http_request_timeout

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
    patch_mcp_timeout
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
    local parallel="${4:-}"
    local auto_destroy="${5:-}"
    local api_key="${6:-}"
    local pod_id="${7:-}"
    local lmstudio_api_key="${8:-}"
    cat << LOAD_EOF
set -e
mkdir -p /root/.config
cat > /root/.config/runpod-lmstudio-deployment.env <<'ENV_EOF'
MODEL_ID="${model}"
MODEL_URL="${url}"
MODEL_CONTEXT_LENGTH="${context_length}"
MODEL_PARALLEL="${parallel}"
AUTO_DESTROY="${auto_destroy}"
RUNPOD_API_KEY="${api_key}"
RUNPOD_POD_ID="${pod_id}"
LMSTUDIO_API_KEY="${lmstudio_api_key}"
ENV_EOF

if [[ ! -x /usr/local/bin/runpod-lmstudio-autostart.sh ]]; then
    echo "[ERROR] Autostart script not found. Run the install step first."
    exit 1
fi

/usr/local/bin/runpod-lmstudio-autostart.sh
LOAD_EOF
}

load_configured_deployments() {
    local pod_id="$1"
    local pod_name="$2"
    local model_id="$3"
    local context_length="${4:-}"
    local parallel="${5:-}"
    local auto_destroy="${6:-}"
    local lmstudio_api_key="$7"
    local url

    if [[ -z "$pod_id" || -z "$model_id" || -z "$lmstudio_api_key" ]]; then
        log_error "Deployment configuration is incomplete."
        return 1
    fi

    url=$(model_url_from_model_id "$model_id")
    if [[ -z "$url" ]]; then
        log_error "No model URL configured for '${model_id}' in ${CONFIG}."
        return 1
    fi

    log_info "Preparing model '${model_id}' on ${pod_name} (${pod_id})..."
    local load_script
    load_script=$(build_load_script "$model_id" "$url" "$context_length" "$parallel" "$auto_destroy" "$RUNPOD_API_KEY" "$pod_id" "$lmstudio_api_key")
    run_remote "$pod_id" "$load_script" || {
        log_error "Model preparation failed for ${pod_name} (${pod_id})."
        return 1
    }

    log_ok "Model loaded on ${pod_name}."
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
    ports: \"22/tcp,1234/tcp\",
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
# Cloudflare accepts the host, plus a Dynamic Redirect Rule (307) per pod.
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

    local _count=${#_pod_ids[@]}
    local _redirect_items=''
    local _i
    for ((_i = 0; _i < _count; _i++)); do
        local _pod_id _config_id _subdomain _target _display_config_id
        _pod_id="${_pod_ids[$_i]}"
        _config_id="${_pod_config_ids[$_i]}"
        _display_config_id=$(format_pod_display_id "$_config_id")
        _subdomain="${_display_config_id}.${cf_domain}"
        _target=$(pod_lmstudio_url "${_pod_id}" 60)

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

    # Build the rules JSON array for the http_request_dynamic_redirect ruleset.
    local _rules_payload
    _rules_payload=$(python3 -c "
import json, sys
rules = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(' ', 1)
    if len(parts) == 2:
        subdomain, target = parts
        ref = 'runpodhelper_' + subdomain.replace('.', '_')
        rules.append({
            'ref': ref,
            'expression': '(http.host eq \"' + subdomain + '\")',
            'action': 'redirect',
            'action_parameters': {
                'from_value': {
                    'status_code': 307,
                    'target_url': {
                        'expression': 'concat(\"' + target + '\", http.request.uri)'
                    },
                    'preserve_query_string': False
                }
            }
        })
print(json.dumps(rules))
" <<< "$_redirect_items")

    # Find existing http_request_dynamic_redirect ruleset for this zone.
    local _ruleset_id
    _ruleset_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('phase')=='http_request_dynamic_redirect']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    local _ruleset_body
    _ruleset_body=$(python3 -c "
import json, sys
print(json.dumps({
    'name': 'runpodhelper redirects',
    'kind': 'zone',
    'phase': 'http_request_dynamic_redirect',
    'rules': json.loads(sys.stdin.read())
}))
" <<< "$_rules_payload")

    local _resp _success
    if [[ -n "$_ruleset_id" ]]; then
        _resp=$(curl -sSL -X PUT \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${_ruleset_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d "$_ruleset_body")
    else
        _resp=$(curl -sSL -X POST \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d "$_ruleset_body")
    fi
    _success=$(echo "$_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2> /dev/null || true)
    if [[ "$_success" == 'True' ]]; then
        log_ok "Dynamic Redirect Rules (307) active for ${_count} pod(s) under ${cf_domain}."
    else
        local _err
        _err=$(echo "$_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:300])" 2> /dev/null || true)
        log_warn "Failed to set Dynamic Redirect Rules: ${_err}"
    fi
}

# Remove all Cloudflare A records and Dynamic Redirect Rules created by set_cloudflare_cnames.
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

    # Delete all proxied A-records with dummy IP 192.0.2.1 (created by set_cloudflare_cnames).
    # These are orphaned when using bulk delete — single-pod delete handles them individually,
    # but bulk delete only removed the ruleset without cleaning up the accompanying A-records.
    local a_record_ids
    a_record_ids=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&content=192.0.2.1&per_page=100" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; print('\n'.join(r['id'] for r in json.load(sys.stdin).get('result', [])))" 2> /dev/null || true)
    local _deleted_a=0
    while IFS= read -r _a_id; do
        [[ -z "$_a_id" ]] && continue
        curl -sSL -o /dev/null -X DELETE \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${_a_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' || true
        ((_deleted_a++)) || true
    done <<< "$a_record_ids"
    if [[ "$_deleted_a" -gt 0 ]]; then
        log_ok "Deleted ${_deleted_a} A-record(s) (dummy IP 192.0.2.1) from DNS."
    fi

    # Delete the zone-level http_request_dynamic_redirect ruleset entirely.
    local ruleset_id
    ruleset_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('phase')=='http_request_dynamic_redirect']; print(m[0]['id'] if m else '')" 2> /dev/null || true)
    if [[ -n "$ruleset_id" ]]; then
        curl -sSL -o /dev/null -X DELETE \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${ruleset_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json'
        log_ok "Deleted Dynamic Redirect ruleset."
    fi
}

# Remove Cloudflare DNS record and Dynamic Redirect Rule for a single pod config ID.
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

    # Remove only this pod's rule from the http_request_dynamic_redirect ruleset.
    local ruleset_id
    ruleset_id=$(curl -sSL -X GET \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); m=[x for x in r if x.get('phase')=='http_request_dynamic_redirect']; print(m[0]['id'] if m else '')" 2> /dev/null || true)

    if [[ -n "$ruleset_id" ]]; then
        local ruleset_resp updated_rules
        ruleset_resp=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${ruleset_id}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        updated_rules=$(echo "$ruleset_resp" | python3 -c "
import json, sys
rules = json.load(sys.stdin).get('result', {}).get('rules', [])
filtered = [r for r in rules if '${subdomain}' not in r.get('expression', '')]
print(json.dumps(filtered))
" 2> /dev/null || echo '[]')
        if [[ "$updated_rules" == '[]' ]]; then
            # No rules left, delete the whole ruleset.
            curl -sSL -o /dev/null -X DELETE \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${ruleset_id}" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json'
        else
            curl -sSL -o /dev/null -X PUT \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${ruleset_id}" \
                -H "Authorization: Bearer ${cf_api_key}" \
                -H 'Content-Type: application/json' \
                -d "{\"name\":\"runpodhelper redirects\",\"kind\":\"zone\",\"phase\":\"http_request_dynamic_redirect\",\"rules\":${updated_rules}}"
        fi
        log_ok "Removed Dynamic Redirect Rule for ${subdomain}."
    fi
}
check_gpu_availability() {
    local gpu="$1"

    log_info "Checking GPU availability..." >&2
    local response resolved_id
    response=$(runpod_api '{"query":"{ gpuTypes { id displayName secureCloud } }"}') || {
        log_error "Could not fetch GPU list from RunPod." >&2
        exit 1
    }

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
        log_ok "  GPU available: ${gpu} (id: ${resolved_id})" >&2
        echo "$resolved_id"
        return 0
    fi

    log_error "  GPU NOT available: ${gpu}" >&2
    log_info "Available secure-cloud GPUs:" >&2
    echo "$response" | python3 -c "
import json, sys
try:
    types = json.load(sys.stdin).get('data', {}).get('gpuTypes', [])
    for t in [x for x in types if x.get('secureCloud')]:
        print('  ' + t.get('displayName', t.get('id', '?')))
except Exception:
    pass" 2> /dev/null >&2 || true
    return 1
}

parse_create_args() {
    local id="" gpu="" hdd="" model="" context_length="" parallel="" auto_destroy="" lmstudio_api_key=""
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
            --parallel)
                parallel="$2"
                shift 2
                ;;
            --auto-destroy)
                auto_destroy="$2"
                shift 2
                ;;
            --lmstudio-api-key)
                lmstudio_api_key="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument for create: $1"
                exit 1
                ;;
        esac
    done
    for arg_spec in "gpu:--gpu" "hdd:--hdd" "model:--model" "context_length:--context-length" "lmstudio_api_key:--lmstudio-api-key"; do
        local var flag
        var="${arg_spec%%:*}"
        flag="${arg_spec##*:}"
        if [[ -z "${!var}" ]]; then
            log_error "Missing required argument: ${flag}"
            exit 1
        fi
    done
    CREATE_ID="$id"
    CREATE_GPU="$gpu"
    CREATE_HDD="$hdd"
    CREATE_MODEL="$model"
    CREATE_CONTEXT_LENGTH="$context_length"
    CREATE_PARALLEL="$parallel"
    CREATE_AUTO_DESTROY="$auto_destroy"
    CREATE_LMSTUDIO_API_KEY="$lmstudio_api_key"
}

cmd_create() {
    parse_create_args "$@"

    # Auto-assign the lowest free numeric ID if none was given
    if [[ -z "$CREATE_ID" ]]; then
        local taken_ids
        taken_ids=$(our_pods_json 2>/dev/null | python3 -c "
import json, sys
pods = json.load(sys.stdin)
names = {p.get('name','') for p in pods}
ids = set()
for name in names:
    if name.startswith('lmstudio-pod-'):
        ids.add(name[len('lmstudio-pod-'):])
for i in range(1, 1000):
    c = str(i).zfill(3)
    if c not in ids:
        print(c)
        break
" 2>/dev/null || echo '')
        if [[ -z "$taken_ids" ]]; then
            log_error "Could not determine a free pod ID."
            exit 1
        fi
        CREATE_ID="$taken_ids"
        log_info "Auto-assigned pod ID: ${CREATE_ID}"
    fi

    local target_name
    target_name=$(pod_name_from_config_id "$CREATE_ID")
    if our_pods_json | jq -e --arg name "$target_name" '.[] | select(.name == $name)' > /dev/null 2>&1; then
        log_warn "Pod '${target_name}' already exists — skipping create."
        exit 0
    fi

    local resolved_gpu
    resolved_gpu=$(check_gpu_availability "$CREATE_GPU") || exit 1

    local model_url
    model_url=$(model_url_from_model_id "$CREATE_MODEL")
    if [[ -z "$model_url" ]]; then
        log_error "Model '${CREATE_MODEL}' not found in ${CONFIG}."
        exit 1
    fi

    load_ssh_pubkey

    local max_attempts=5
    local attempt
    local pod_id=''
    local pod_ids=()
    local pod_config_ids=("$CREATE_ID")
    local pod_name
    pod_name=$(pod_name_from_config_id "$CREATE_ID")

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if [[ $attempt -gt 1 ]]; then
            log_info "Retry attempt ${attempt}/${max_attempts}..."
        fi

        log_info "Creating pod from CLI arguments..."
        pod_ids=()

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

        # --- Step 1: create pod ---
        log_info "Creating pod: ${pod_name} | ${resolved_gpu} | ${CREATE_HDD} GB"
        pod_id=$(_create_pod_with_fallback "$pod_name" "$resolved_gpu" "$CREATE_HDD") || {
            log_error "Pod could not be created."
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed while creating the pod."
                exit 1
            fi
        }
        log_ok "Pod created: ${pod_id}"
        pod_ids+=("$pod_id")

        # --- Step 2: wait for RUNNING ---
        echo ""
        log_info "Waiting for pod to reach RUNNING..."
        if ! wait_for_pod "$pod_id"; then
            log_error "Pod ${pod_id} did not reach RUNNING."
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
        local ssh_info host port
        ssh_info=$(pod_ssh_details "$pod_id") || {
            log_error "Pod ${pod_id} is not reachable via SSH."
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed at SSH reachability."
                exit 1
            fi
        }
        host=$(echo "$ssh_info" | awk '{print $1}')
        port=$(echo "$ssh_info" | awk '{print $2}')
        log_ok "  Pod ${pod_id}: ssh root@${host} -p ${port}"

        # --- Step 4: install LM Studio + start server ---
        echo ""
        log_info "Installing LM Studio and starting server..."
        local install_script
        install_script=$(build_install_script)
        log_info "Installing on ${pod_name} (${pod_id})..."
        if ! run_remote "${pod_id}" "$install_script"; then
            log_error "Install failed for ${pod_name} (${pod_id})."
            rollback
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Will retry..."
                continue
            else
                log_error "All ${max_attempts} attempts failed at LM Studio install."
                exit 1
            fi
        fi
        log_ok "LM Studio installed and server started on ${pod_name}."

        # --- Step 5: configure deployments and load models ---
        echo ""
        log_info "Configuring deployment and loading model..."
        if ! load_configured_deployments \
            "$pod_id" \
            "$pod_name" \
            "$CREATE_MODEL" \
            "$CREATE_CONTEXT_LENGTH" \
            "$CREATE_PARALLEL" \
            "$CREATE_AUTO_DESTROY" \
            "$CREATE_LMSTUDIO_API_KEY"; then
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
    log_ok "Pod ready. Summary:"
    printf "  %-14s %-30s %-20s %s\n" "Config ID" "Name" "Pod ID" "GPU"
    printf "  %-14s %-30s %-20s %s\n" "---------" "----" "------" "---"
    printf "  %-14s %-30s %-20s %s\n" "$(format_pod_display_id "$CREATE_ID")" "$(pod_display_name_from_config_id "$CREATE_ID")" "${pod_id}" "${resolved_gpu}"
    echo ""
    log_info "LM Studio endpoint pattern: https://<pod-id>-1234.proxy.runpod.net"
    log_info "Deployment was loaded automatically."

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
    local subcommand="${1:-}"
    if [[ "$subcommand" != "quality" && "$subcommand" != "quantity" ]]; then
        log_error "Usage: test {quality|quantity} [--runs <n>]"
        exit 1
    fi
    shift
    local run_count
    if [[ "$subcommand" == "quality" ]]; then
        run_count=1
    else
        run_count=20
    fi
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
    local timestamp logs_dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    logs_dir="${PROJECT_DIR}/logs/test-${timestamp}"
    mkdir -p "$logs_dir"

    # quantity: run N parallel browser-MCP tests against the load balancer
    if [[ "$subcommand" == "quantity" ]]; then
        local scale_run_dir="${PROJECT_DIR}/logs/scale"
        local cf_domain="${CLOUDFLARE_DOMAIN:-}"
        local lb_url lb_api_key='' model_id

        if [[ -n "$cf_domain" ]]; then
            lb_url="https://llm.${cf_domain}"
        elif [[ -f "${scale_run_dir}/php.port" ]]; then
            lb_url="http://127.0.0.1:$(cat "${scale_run_dir}/php.port")"
        else
            log_error "Load balancer URL could not be determined (set CLOUDFLARE_DOMAIN or start the load balancer first)."
            exit 1
        fi

        # Fetch API key via SSH from one of the LB's backing pods (same approach as normal test)
        local lb_pod_id
        lb_pod_id=$(python3 -c "
import json, sys
try:
    with open('${scale_run_dir}/pods_status.json') as f:
        d = json.load(f)
    pods = d.get('pods', [])
    print(pods[0].get('pod_id', '') if pods else '')
except Exception:
    print('')
" 2> /dev/null || echo '')
        if [[ -n "$lb_pod_id" ]]; then
            lb_api_key=$(pod_lmstudio_api_key_from_pod_id "$lb_pod_id")
        fi
        if [[ -z "$lb_api_key" ]]; then
            log_error "Could not fetch API key from load balancer pod (is the load balancer running?)."
            exit 1
        fi

        model_id=$(python3 -c "
import json, sys
try:
    with open('${scale_run_dir}/pods_status.json') as f:
        d = json.load(f)
    pods = d.get('pods', [])
    print(pods[0].get('model_id', '') if pods else '')
except Exception:
    print('')
" 2> /dev/null || echo '')

        if [[ -z "$model_id" ]]; then
            log_error "Could not determine model from load balancer state (is the load balancer running?)."
            exit 1
        fi

        log_info "Starting ${run_count} parallel browser tests against LB: ${lb_url} (model: ${model_id})..."
        declare -a parallel_pids=()
        declare -a parallel_run_logs=()
        for i in $(seq 1 "$run_count"); do
            local run_log_file call_log_file
            run_log_file="${logs_dir}/lb.parallel-${i}.run.log"
            call_log_file="${logs_dir}/lb.parallel-${i}.call.log"
            php "${PACKAGE_DIR}/runpod.php" \
                "--mode=parallel-browser" \
                "--pod-url=${lb_url}" \
                "--model-id=${model_id}" \
                "--pod-api-key=${lb_api_key}" \
                "--run-log=${run_log_file}" \
                "--call-log=${call_log_file}" \
                "--project-dir=${PROJECT_DIR}" \
                > /dev/null 2>&1 &
            parallel_pids+=("$!")
            parallel_run_logs+=("${run_log_file}")
        done
        echo ""
        log_info "${run_count} parallel browser tests running. Logs: ${logs_dir}"
        local failed_count=0 succeeded_count=0
        for i in "${!parallel_pids[@]}"; do
            local job_num=$((i + 1))
            local result_line exit_code
            # wait for the process to finish before reading the log
            wait "${parallel_pids[$i]}"
            exit_code=$?
            result_line=$(grep -m1 '✅ Response:\|⛔ Failed:\|⛔ Response failed:' "${parallel_run_logs[$i]}" 2> /dev/null || true)
            if [[ $exit_code -eq 0 ]] && echo "$result_line" | grep -q '✅'; then
                log_ok "Browser test ${job_num}/${run_count} finished. ${result_line}"
                succeeded_count=$((succeeded_count + 1))
            else
                log_ok "Browser test ${job_num}/${run_count} finished. ${result_line}"
                failed_count=$((failed_count + 1))
            fi
        done
        local success_rate_abs="${succeeded_count}/${run_count}"
        local success_rate_pct
        success_rate_pct=$(awk "BEGIN { printf \"%.1f\", (${succeeded_count} / ${run_count}) * 100 }")
        local worker_count
        worker_count=$(python3 -c "
import json, sys
try:
    with open('${scale_run_dir}/pods_status.json') as f:
        d = json.load(f)
    print(len(d.get('pods', [])))
except Exception:
    print(0)
" 2>/dev/null || echo '0')
        echo ""
        log_ok "All ${run_count} parallel browser tests finished."
        local summary_line="✅ Successful: ${succeeded_count}  ⛔ Failed: ${failed_count}  |  ${success_rate_abs} = ${success_rate_pct}% [Runs: ${run_count}, Pods: ${worker_count}] | Logs: ${logs_dir}"
        log_ok "${summary_line}"
        echo "${summary_line}" >> "${PROJECT_DIR}/logs/runs.log"
        if [[ "$failed_count" -gt 0 ]]; then
            exit 1
        fi
        return 0
    fi

    local pods_json count
    pods_json=$(our_pods_json) || pods_json='[]'
    count=$(echo "$pods_json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        log_error "No configured pods found."
        exit 1
    fi

    declare -a test_pids=()
    declare -a test_labels=()
    declare -a test_run_logs=()
    declare -a test_call_logs=()

    while IFS= read -r pod_item; do
        local pod_id pod_name pod_config_id display_pod_config_id pod_status_val gpu model_id pod_url run_log_file call_log_file lmstudio_api_key
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
            pod_url=$(pod_lmstudio_url "$pod_id")
        fi
        lmstudio_api_key=$(pod_lmstudio_api_key_from_pod_id "$pod_id")
        if [[ -z "$lmstudio_api_key" ]]; then
            log_error "Missing LM Studio API key for pod ${display_pod_config_id}."
            continue
        fi
        model_id=$(curl -sf --max-time 10 -H "Authorization: Bearer ${lmstudio_api_key}" "${pod_url}/api/v0/models" 2> /dev/null | python3 -c "
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
            "--pod-api-key=${lmstudio_api_key}" \
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
        local lmstudio_url
        lmstudio_url=$(pod_lmstudio_url "$pod_id")
        local http_code lmstudio_api_key
        lmstudio_api_key=$(pod_lmstudio_api_key_from_pod_id "$pod_id")
        if [[ -n "$lmstudio_api_key" ]]; then
            http_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${lmstudio_api_key}" "${lmstudio_url}/api/v0/models" 2> /dev/null || echo "000")
        else
            http_code="000"
        fi
        echo "  URL:       ${lmstudio_url}"
        if [[ "$http_code" == "200" ]]; then
            log_ok "  Proxy:     reachable (${lmstudio_url})"
        elif [[ "$http_code" == "401" ]]; then
            log_warn "  Proxy:     unauthorized (invalid LM Studio API key)"
        else
            log_warn "  Proxy:     not reachable (${lmstudio_url}, HTTP ${http_code})"
            log_warn "  Note:      local LM Studio can still be running even if the external proxy is not reachable yet."
        fi

        # --- LM Studio running locally? / model loaded? (via local HTTP API over SSH) ---
        local local_api_output local_api_summary local_api_status loaded_model_id loaded_model_summary
        local_api_output=$(run_remote "$pod_id" 'curl -sf http://127.0.0.1:1235/api/v0/models' 'no' 2> /dev/null || echo '')
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

        # --- GPU utilization (via SSH, nvidia-smi) ---
        local gpu_util
        gpu_util=$(run_remote "$pod_id" 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo -1' 'no' 2> /dev/null | tr -d '[:space:]' || echo '-1')
        [[ "$gpu_util" =~ ^-?[0-9]+$ ]] || gpu_util='-1'
        echo "  GPU:       ${gpu_util}%"

        echo ""
    done < <(echo "$pods_json" | jq -c '.[]')
}

# -------------------------------------------------------------------
# scale
# -------------------------------------------------------------------

# Returns the Cloudflare zone ID for a given domain (walks up parent domains).
_cf_find_zone_id() {
    local domain="$1"
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"
    IFS='.' read -ra _czparts <<< "$domain"
    local _czn=${#_czparts[@]}
    local _czj
    for ((_czj = 0; _czj < _czn - 1; _czj++)); do
        local _czcandidate
        _czcandidate=$(
            IFS='.'
            echo "${_czparts[*]:$_czj}"
        )
        local _czresp
        _czresp=$(curl -sSL -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=${_czcandidate}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        local _czid
        _czid=$(echo "$_czresp" | python3 -c \
            "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$_czid" ]]; then
            echo "$_czid"
            return 0
        fi
    done
    return 1
}

# Installs cloudflared if missing.
_lb_ensure_cloudflared() {
    if command -v cloudflared > /dev/null 2>&1; then
        return 0
    fi
    log_info "Installing cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
}

# Creates a Cloudflare Tunnel and CNAME for llm.{CLOUDFLARE_DOMAIN}, starts cloudflared.
_lb_setup_tunnel() {
    local lb_port="$1"
    local scale_run_dir="$2"
    mkdir -p "$scale_run_dir"
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"
    local cf_domain="${CLOUDFLARE_DOMAIN:-}"
    if [[ -z "$cf_api_key" || -z "$cf_domain" ]]; then
        log_warn "CLOUDFLARE_API_KEY or CLOUDFLARE_DOMAIN not set, skipping tunnel setup."
        return 0
    fi

    _lb_ensure_cloudflared

    # Determine account ID from the zone response (works with Zone-scoped tokens)
    local account_id
    IFS='.' read -ra _acct_parts <<< "$cf_domain"
    local _acct_n=${#_acct_parts[@]}
    local _acct_j
    for ((_acct_j = 0; _acct_j < _acct_n - 1; _acct_j++)); do
        local _acct_candidate
        _acct_candidate=$(
            IFS='.'
            echo "${_acct_parts[*]:$_acct_j}"
        )
        local _acct_resp
        _acct_resp=$(curl -sSL "https://api.cloudflare.com/client/v4/zones?name=${_acct_candidate}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json')
        account_id=$(echo "$_acct_resp" | python3 -c \
            "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['account']['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$account_id" ]]; then
            break
        fi
    done
    if [[ -z "$account_id" ]]; then
        log_warn "Could not determine Cloudflare account ID, skipping tunnel setup."
        return 0
    fi

    # Delete any pre-existing tunnel with the same name
    local tunnel_name='runpodhelper-lb'
    local existing_tunnel_id
    existing_tunnel_id=$(curl -sSL "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel?name=${tunnel_name}" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); active=[t for t in r if not t.get('deleted_at')]; print(active[0]['id'] if active else '')" 2> /dev/null || true)
    if [[ -n "$existing_tunnel_id" ]]; then
        # Kill any leftover cloudflared process before deleting the tunnel via API
        pkill -f 'cloudflared tunnel' 2> /dev/null || true
        sleep 3
        # Clean up active connections before deleting
        curl -sSL -X DELETE \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${existing_tunnel_id}/connections" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' > /dev/null 2>&1 || true
        sleep 3
        local del_resp
        del_resp=$(curl -sSL -X DELETE \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${existing_tunnel_id}?force=true" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' 2> /dev/null || true)
        if ! echo "$del_resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)" 2> /dev/null; then
            local del_err
            del_err=$(echo "$del_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:200])" 2> /dev/null || true)
            log_warn "Failed to delete existing tunnel: ${del_err}"
            return 0
        fi
        sleep 2
    fi

    # Generate a random 32-byte tunnel secret
    local tunnel_secret
    tunnel_secret=$(python3 -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())")

    # Create tunnel
    local create_resp tunnel_id
    create_resp=$(curl -sSL -X POST \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel" \
        -H "Authorization: Bearer ${cf_api_key}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${tunnel_name}\",\"tunnel_secret\":\"${tunnel_secret}\"}")
    tunnel_id=$(echo "$create_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('id',''))" 2> /dev/null || true)
    if [[ -z "$tunnel_id" ]]; then
        local err
        err=$(echo "$create_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:200])" 2> /dev/null || true)
        log_warn "Failed to create Cloudflare tunnel: ${err}"
        return 0
    fi
    log_ok "Cloudflare tunnel created (${tunnel_id})."

    # Write credentials file for cloudflared
    local creds_file="${scale_run_dir}/cloudflared-credentials.json"
    python3 -c "
import json, sys
print(json.dumps({'AccountTag': sys.argv[1], 'TunnelSecret': sys.argv[2], 'TunnelID': sys.argv[3]}))
" "$account_id" "$tunnel_secret" "$tunnel_id" > "$creds_file"

    # Write cloudflared ingress config
    local lb_subdomain="llm.${cf_domain}"
    local config_file="${scale_run_dir}/cloudflared-config.yml"
    cat > "$config_file" << CFEOF
tunnel: ${tunnel_id}
credentials-file: ${creds_file}
ingress:
  - hostname: ${lb_subdomain}
    service: http://127.0.0.1:${lb_port}
  - service: http_status:404
CFEOF

    # Create CNAME DNS record pointing to the tunnel
    local zone_id
    zone_id=$(_cf_find_zone_id "$cf_domain") || true
    if [[ -n "$zone_id" ]]; then
        local existing_dns_id
        existing_dns_id=$(curl -sSL \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${lb_subdomain}" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
        if [[ -n "$existing_dns_id" ]]; then
            curl -sSL -X DELETE \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${existing_dns_id}" \
                -H "Authorization: Bearer ${cf_api_key}" > /dev/null 2>&1 || true
        fi
        local dns_resp
        dns_resp=$(curl -sSL -X POST \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' \
            -d "{\"type\":\"CNAME\",\"name\":\"${lb_subdomain}\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}")
        if echo "$dns_resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)" 2> /dev/null; then
            log_ok "DNS CNAME: ${lb_subdomain} \u2192 ${tunnel_id}.cfargotunnel.com"
        else
            local dns_err
            dns_err=$(echo "$dns_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:200])" 2> /dev/null || true)
            log_warn "Failed to create DNS CNAME: ${dns_err}"
        fi
    fi

    # Persist IDs for cleanup
    echo "$tunnel_id" > "${scale_run_dir}/tunnel.id"
    echo "$account_id" > "${scale_run_dir}/tunnel.account"

    # Start cloudflared tunnel in background
    cloudflared tunnel --config "$config_file" run \
        >> "${scale_run_dir}/tunnel.log" 2>&1 &
    echo $! > "${scale_run_dir}/tunnel.pid"
    log_ok "Cloudflare tunnel running (PID $(cat "${scale_run_dir}/tunnel.pid"))."
    log_ok "  LB endpoint: https://${lb_subdomain}"
    log_info "  Log: ${scale_run_dir}/tunnel.log"
}

# Stops cloudflared, deletes the tunnel and its CNAME DNS record.
_lb_cleanup_tunnel() {
    local scale_run_dir="$1"
    local cf_api_key="${CLOUDFLARE_API_KEY:-}"

    # Stop cloudflared process (via PID file, then fallback to pkill)
    local tunnel_pid_file="${scale_run_dir}/tunnel.pid"
    if [[ -f "$tunnel_pid_file" ]]; then
        local tunnel_pid
        tunnel_pid=$(cat "$tunnel_pid_file")
        if kill "$tunnel_pid" 2> /dev/null; then
            log_ok "Cloudflare tunnel stopped (PID ${tunnel_pid})."
        fi
        rm -f "$tunnel_pid_file"
    fi
    pkill -f 'cloudflared tunnel' 2> /dev/null || true
    sleep 3

    local tunnel_id_file="${scale_run_dir}/tunnel.id"
    local account_id_file="${scale_run_dir}/tunnel.account"
    if [[ -f "$tunnel_id_file" && -f "$account_id_file" && -n "$cf_api_key" ]]; then
        local tunnel_id account_id
        tunnel_id=$(cat "$tunnel_id_file")
        account_id=$(cat "$account_id_file")

        # Remove CNAME DNS record
        local cf_domain="${CLOUDFLARE_DOMAIN:-}"
        if [[ -n "$cf_domain" ]]; then
            local zone_id
            zone_id=$(_cf_find_zone_id "$cf_domain") || true
            if [[ -n "$zone_id" ]]; then
                local lb_subdomain="llm.${cf_domain}"
                local dns_id
                dns_id=$(curl -sSL \
                    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${lb_subdomain}" \
                    -H "Authorization: Bearer ${cf_api_key}" \
                    -H 'Content-Type: application/json' \
                    | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2> /dev/null || true)
                if [[ -n "$dns_id" ]]; then
                    curl -sSL -X DELETE \
                        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${dns_id}" \
                        -H "Authorization: Bearer ${cf_api_key}" > /dev/null 2>&1 || true
                    log_ok "DNS CNAME for ${lb_subdomain} removed."
                fi
            fi
        fi

        # Clean up active connections before deleting
        curl -sSL -X DELETE \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/connections" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' > /dev/null 2>&1 || true
        sleep 3
        # Delete tunnel
        local del_resp
        del_resp=$(curl -sSL -X DELETE \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}?force=true" \
            -H "Authorization: Bearer ${cf_api_key}" \
            -H 'Content-Type: application/json' 2> /dev/null || true)
        if echo "$del_resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)" 2> /dev/null; then
            log_ok "Cloudflare tunnel deleted."
        else
            local del_err
            del_err=$(echo "$del_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d.get('errors',d))[:200])" 2> /dev/null || true)
            log_warn "Failed to delete tunnel: ${del_err}"
        fi
        rm -f "$tunnel_id_file" "$account_id_file"
    fi

    rm -f "${scale_run_dir}/cloudflared-credentials.json" "${scale_run_dir}/cloudflared-config.yml"
}

# Global variables set by _lb_parse_args
LB_POD_COUNT=1
LB_CHECK_INTERVAL=15
LB_GPU=''
LB_HDD=''
LB_MODEL=''
LB_CONTEXT_LENGTH=''
LB_PARALLEL=''
LB_API_KEY=''
LB_PROJECT_DIR=''
LB_AUTO_DESTROY=''

_lb_parse_args() {
    LB_POD_COUNT=1
    LB_CHECK_INTERVAL=15
    LB_GPU=''
    LB_HDD=''
    LB_MODEL=''
    LB_CONTEXT_LENGTH=''
    LB_PARALLEL=''
    LB_API_KEY=''
    LB_PROJECT_DIR="${PROJECT_DIR}"
    LB_AUTO_DESTROY=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pod-count)
                LB_POD_COUNT="$2"
                shift 2
                ;;
            --check-interval)
                LB_CHECK_INTERVAL="$2"
                shift 2
                ;;
            --gpu)
                LB_GPU="$2"
                shift 2
                ;;
            --hdd)
                LB_HDD="$2"
                shift 2
                ;;
            --model)
                LB_MODEL="$2"
                shift 2
                ;;
            --context-length)
                LB_CONTEXT_LENGTH="$2"
                shift 2
                ;;
            --parallel)
                LB_PARALLEL="$2"
                shift 2
                ;;
            --lmstudio-api-key)
                LB_API_KEY="$2"
                shift 2
                ;;
            --project-dir)
                LB_PROJECT_DIR="$2"
                shift 2
                ;;
            --auto-destroy)
                LB_AUTO_DESTROY="$2"
                shift 2
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

cmd_scale() {
    local action="${1:-}"
    shift || true
    case "$action" in
        --start) _cmd_lb_start "$@" ;;
        --stop) _cmd_lb_stop "$@" ;;
        --refresh) _cmd_lb_refresh "$@" ;;
        --pod-count) _cmd_lb_scale_to "$@" ;;
        *)
            log_error "Usage: $0 scale {--start|--stop|--refresh|--pod-count} [options]"
            exit 1
            ;;
    esac
}

_cmd_lb_scale_to() {
    # Usage: scale --pod-count <n> [--project-dir <dir>]
    local target=''
    local project_dir="${PROJECT_DIR}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir) project_dir="$2"; shift 2 ;;
            [0-9]*) target="$1"; shift ;;
            *) log_error "Unknown argument: $1"; exit 1 ;;
        esac
    done

    local scale_run_dir="${project_dir}/logs/scale"
    local health_pid_file="${scale_run_dir}/health.pid"
    local scale_override_file="${scale_run_dir}/scale-override"

    # Require a running cluster
    if [[ ! -f "$health_pid_file" ]] || ! kill -0 "$(cat "$health_pid_file")" 2>/dev/null; then
        log_error "Scale is not running. Start it first with: $0 scale --start ..."
        exit 1
    fi

    if [[ -z "$target" ]] || ! [[ "$target" =~ ^[0-9]+$ ]] || [[ "$target" -lt 1 ]]; then
        log_error "Usage: $0 scale --pod-count <n>  (n must be a positive integer)"
        exit 1
    fi

    printf '%s\n' "$target" > "$scale_override_file"
    log_ok "Pod count set to ${target}. The health loop will apply this on the next tick."
}

_cmd_lb_refresh() {
    _lb_parse_args "$@"
    local scale_run_dir="${LB_PROJECT_DIR}/logs/scale"
    local state_file="${scale_run_dir}/pods_status.json"

    if [[ ! -f "$state_file" ]]; then
        log_error "Scale state not found. Is the cluster running?"
        exit 1
    fi

    # Read model_id and parallel from state + CLI args
    local model_id parallel_val
    model_id=$(python3 -c "
import json
with open('${state_file}') as f:
    d = json.load(f)
pods = d.get('pods', [])
print(pods[0].get('model_id', '') if pods else '')
" 2>/dev/null || echo '')

    if [[ -z "$model_id" ]]; then
        log_error "Could not determine model from cluster state."
        exit 1
    fi

    parallel_val="${LB_PARALLEL:-2}"
    local context_length="${LB_CONTEXT_LENGTH:-65536}"

    # Collect pod IDs
    local pod_ids
    pod_ids=$(python3 -c "
import json
with open('${state_file}') as f:
    d = json.load(f)
for p in d.get('pods', []):
    print(p['pod_id'])
" 2>/dev/null)

    local pod_count
    pod_count=$(echo "$pod_ids" | wc -l)
    log_info "Refreshing LLM on ${pod_count} pods (unload + reload ${model_id}, parallel=${parallel_val}, context=${context_length})..."

    local refresh_script
    refresh_script=$(cat <<REMOTE_EOF
#!/bin/bash
set -e
LMS="/root/.lmstudio/bin/lms"
MODEL_ID="${model_id}"
CONTEXT_LENGTH="${context_length}"
PARALLEL="${parallel_val}"
KV_CACHE_TYPE=""

echo "[REFRESH] Unloading all models..."
\$LMS unload --all 2>/dev/null || true
sleep 2

echo "[REFRESH] Loading \${MODEL_ID} (context=\${CONTEXT_LENGTH}, parallel=\${PARALLEL})..."
load_args=("\${MODEL_ID}" --context-length "\${CONTEXT_LENGTH}" --parallel "\${PARALLEL}")
if [[ -n "\${KV_CACHE_TYPE}" ]]; then
    echo "[REFRESH] Warning: --kv-cache-type is not supported by lms load, ignoring."
fi
\$LMS load "\${load_args[@]}" < /dev/null 2>&1

# Wait for model to appear in lms ps
for attempt in \$(seq 1 30); do
    if \$LMS ps 2>/dev/null | awk -v id="\${MODEL_ID}" '\$1 == id { found = 1 } END { exit(found ? 0 : 1) }'; then
        echo "[REFRESH] Model loaded successfully."
        exit 0
    fi
    sleep 2
done
echo "[REFRESH] ERROR: Model did not appear after 60s."
exit 1
REMOTE_EOF
)

    # Run refresh on all pods in parallel
    local -a refresh_pids=()
    local -a refresh_pod_ids=()
    while IFS= read -r pod_id; do
        [[ -z "$pod_id" ]] && continue
        run_remote "$pod_id" "$refresh_script" 'no' > "/tmp/lb_refresh_${pod_id}.log" 2>&1 &
        refresh_pids+=("$!")
        refresh_pod_ids+=("$pod_id")
    done <<< "$pod_ids"

    # Wait for all and report results
    local ok=0 fail=0
    for idx in "${!refresh_pids[@]}"; do
        local pid="${refresh_pids[$idx]}"
        local pod_id="${refresh_pod_ids[$idx]}"
        if wait "$pid"; then
            ok=$((ok + 1))
            log_ok "Pod ${pod_id}: refreshed."
        else
            fail=$((fail + 1))
            log_error "Pod ${pod_id}: refresh FAILED."
            cat "/tmp/lb_refresh_${pod_id}.log" 2>/dev/null | tail -5
        fi
        rm -f "/tmp/lb_refresh_${pod_id}.log"
    done

    echo ""
    if [[ "$fail" -eq 0 ]]; then
        log_ok "All ${pod_count} pods refreshed successfully."
    else
        log_error "${fail}/${pod_count} pods failed to refresh."
        exit 1
    fi
}

_cmd_lb_start() {
    _lb_parse_args "$@"
    local scale_run_dir="${LB_PROJECT_DIR}/logs/scale"
    local health_pid_file="${scale_run_dir}/health.pid"
    local php_pid_file="${scale_run_dir}/php.pid"

    for _fv_flag in 'LB_GPU:--gpu' 'LB_HDD:--hdd' 'LB_MODEL:--model' 'LB_CONTEXT_LENGTH:--context-length' 'LB_API_KEY:--lmstudio-api-key'; do
        local _fv="${_fv_flag%%:*}" _ff="${_fv_flag##*:}"
        if [[ -z "${!_fv}" ]]; then
            log_error "Missing required argument: ${_ff}"
            exit 1
        fi
    done

    mkdir -p "$scale_run_dir"

    # Kill any orphaned health loop or balancer processes from previous sessions
    pkill -f '_lb_health_loop' 2> /dev/null || true
    pkill -f 'scale\.php' 2> /dev/null || true

    if [[ -f "$health_pid_file" ]] && kill -0 "$(cat "$health_pid_file")" 2> /dev/null; then
        log_warn "Scale already running (PID $(cat "$health_pid_file")). Run --stop first."
        exit 1
    fi

    log_info "Deleting all existing pods before starting..."
    bash "${PACKAGE_DIR}/runpod.sh" delete --all
    log_ok "All pods deleted."
    rm -rf "${scale_run_dir}/creating"
    mkdir -p "${scale_run_dir}/creating"

    local health_loop_args=(
        --pod-count "$LB_POD_COUNT"
        --check-interval "$LB_CHECK_INTERVAL"
        --gpu "$LB_GPU"
        --hdd "$LB_HDD"
        --model "$LB_MODEL"
        --context-length "$LB_CONTEXT_LENGTH"
        --lmstudio-api-key "$LB_API_KEY"
        --project-dir "$LB_PROJECT_DIR"
    )
    [[ -n "$LB_PARALLEL" ]] && health_loop_args+=(--parallel "$LB_PARALLEL")
    bash "${PACKAGE_DIR}/runpod.sh" _lb_health_loop \
        "${health_loop_args[@]}" \
        >> "${scale_run_dir}/health.log" 2>&1 &
    echo $! > "$health_pid_file"
    log_ok "Health loop started (PID $(cat "$health_pid_file"))."
    log_info "  Log: ${scale_run_dir}/health.log"

    if [[ -n "${LB_AUTO_DESTROY:-}" && "${LB_AUTO_DESTROY}" -gt 0 ]]; then
        local auto_destroy_pid_file="${scale_run_dir}/auto-destroy.pid"
        (
            sleep "${LB_AUTO_DESTROY}"
            # Remove own PID file before calling --stop to prevent _cmd_lb_stop
            # from sending SIGTERM to itself (the --stop process is a child of this subshell).
            rm -f "${scale_run_dir}/auto-destroy.pid"
            bash "${PACKAGE_DIR}/runpod.sh" scale --stop --project-dir "${LB_PROJECT_DIR}" \
                >> "${scale_run_dir}/auto-destroy.log" 2>&1
        ) &
        echo $! > "$auto_destroy_pid_file"
        log_ok "Auto-destroy scheduled in ${LB_AUTO_DESTROY}s (PID $(cat "$auto_destroy_pid_file"))."
        log_info "  Log: ${scale_run_dir}/auto-destroy.log"
    fi

    local lb_port
    lb_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
    echo "$lb_port" > "${scale_run_dir}/php.port"
    LB_STATE_FILE="${scale_run_dir}/pods_status.json" \
        php -S "0.0.0.0:${lb_port}" "${PACKAGE_DIR}/scale.php" \
        >> "${scale_run_dir}/php.log" 2>&1 &
    echo $! > "$php_pid_file"
    log_ok "PHP balancer started on port ${lb_port} (PID $(cat "$php_pid_file"))."
    log_info "  Log: ${scale_run_dir}/php.log"

    _lb_setup_tunnel "$lb_port" "$scale_run_dir"
}

_cmd_lb_stop() {
    _lb_parse_args "$@"
    local scale_run_dir="${LB_PROJECT_DIR}/logs/scale"
    local health_pid_file="${scale_run_dir}/health.pid"
    local php_pid_file="${scale_run_dir}/php.pid"

    # Kill auto-destroy watcher if still running
    local auto_destroy_pid_file="${scale_run_dir}/auto-destroy.pid"
    if [[ -f "$auto_destroy_pid_file" ]]; then
        local auto_destroy_pid
        auto_destroy_pid=$(cat "$auto_destroy_pid_file")
        pkill -TERM -P "$auto_destroy_pid" 2> /dev/null || true
        kill "$auto_destroy_pid" 2> /dev/null || true
        rm -f "$auto_destroy_pid_file"
        log_ok "Auto-destroy watcher stopped."
    fi

    if [[ -f "$health_pid_file" ]]; then
        local health_pid
        health_pid=$(cat "$health_pid_file")
        if kill "$health_pid" 2> /dev/null; then
            log_ok "Health loop stopped (PID ${health_pid})."
        else
            log_warn "Health loop PID ${health_pid} was not running."
        fi
        rm -f "$health_pid_file"
    else
        log_warn "Health loop PID file not found."
    fi
    # Kill any remaining orphaned health loop processes
    pkill -f '_lb_health_loop' 2> /dev/null || true

    # Kill all in-progress scale-up background jobs
    local creating_dir="${scale_run_dir}/creating"
    for pid_file in "${creating_dir}/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        local scale_up_pid
        scale_up_pid=$(cat "$pid_file")
        pkill -TERM -P "$scale_up_pid" 2> /dev/null || true
        kill "$scale_up_pid" 2> /dev/null || true
        log_warn "In-progress scale-up job (PID ${scale_up_pid}) killed."
    done
    rm -rf "$creating_dir"

    if [[ -f "$php_pid_file" ]]; then
        local php_pid
        php_pid=$(cat "$php_pid_file")
        if kill "$php_pid" 2> /dev/null; then
            log_ok "PHP balancer stopped (PID ${php_pid})."
        else
            log_warn "PHP balancer PID ${php_pid} was not running."
        fi
        rm -f "$php_pid_file"
    else
        log_warn "PHP balancer PID file not found."
    fi

    _lb_cleanup_tunnel "$scale_run_dir"

    log_info "Deleting all pods..."
    bash "${PACKAGE_DIR}/runpod.sh" delete --all
    # Wait briefly and delete again to catch pods created in the race window
    sleep 10
    bash "${PACKAGE_DIR}/runpod.sh" delete --all 2> /dev/null || true
    log_ok "All pods deleted."

    # Always clean up pod A-records and redirect rules explicitly — delete --all skips
    # this when no pods are found (early return), leaving orphaned DNS entries behind.
    log_info "Cleaning up Cloudflare DNS records and redirect rules..."
    clear_cloudflare_redirects

    rm -rf "${scale_run_dir}"
    log_ok "All logs deleted."
}

# Queries a single pod (GPU util + loaded model) and writes a JSON result file.
# Called in parallel by the health loop — one background job per pod.
_lb_collect_pod_info() {
    local pod_id="$1" pod_name="$2" out_file="$3"
    local config_id url gpu_util model_id

    config_id=$(pod_config_id_from_name "$pod_name" 2> /dev/null || echo '')
    url=$(pod_lmstudio_url "$pod_id")

    gpu_util=$(run_remote "$pod_id" \
        'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo -1' \
        'no' 2> /dev/null | tr -d '[:space:]' || echo '-1')
    [[ "$gpu_util" =~ ^-?[0-9]+$ ]] || gpu_util='-1'

    model_id=$(run_remote "$pod_id" \
        'curl -sf http://127.0.0.1:1235/api/v0/models 2>/dev/null' \
        'no' 2> /dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    loaded = [m for m in data.get("data", []) if m.get("state") == "loaded"]
    print(loaded[0]["id"] if loaded else "")
except Exception:
    print("")
' 2> /dev/null || echo '')

    python3 -c "import json; print(json.dumps({'url': '$url', 'pod_id': '$pod_id', 'config_id': '$config_id', 'model_id': '$model_id', 'gpu_util': $gpu_util}))" > "$out_file"
}

_cmd_lb_health_loop() {
    _lb_parse_args "$@"
    cd "$LB_PROJECT_DIR" || exit 1
    local scale_run_dir="${LB_PROJECT_DIR}/logs/scale"
    local state_file="${scale_run_dir}/pods_status.json"
    local creating_dir="${scale_run_dir}/creating"
    mkdir -p "$scale_run_dir"
    mkdir -p "$creating_dir"

    log_info "[LB] Health loop started (PID $$, interval: ${LB_CHECK_INTERVAL}s, pod-count: ${LB_POD_COUNT}, parallel: ${LB_PARALLEL:-default})."

    while true; do
        local now
        now=$(date +%s)

        # Remove stale .creating files (older than 15 minutes)
        for stale_lock in "${creating_dir}/"*.creating; do
            [[ -f "$stale_lock" ]] || continue
            local stale_age
            stale_age=$((now - $(stat -c %Y "$stale_lock")))
            if [[ "$stale_age" -gt 900 ]]; then
                log_warn "[LB] Removing stale create lock: $(basename "$stale_lock") (${stale_age}s old)."
                local stale_id
                stale_id=$(basename "$stale_lock" .creating)
                rm -f "$stale_lock" "${creating_dir}/${stale_id}.done"
            fi
        done

        # Query all pods in parallel (one background job per pod)
        local pods_json poll_dir
        pods_json=$(our_pods_json 2> /dev/null) || pods_json='[]'
        poll_dir=$(mktemp -d)
        local -a bg_pids=()
        while read -r pod; do
            local pod_id pod_name
            pod_id=$(echo "$pod" | jq -r '.id')
            pod_name=$(echo "$pod" | jq -r '.name')
            _lb_collect_pod_info "$pod_id" "$pod_name" "${poll_dir}/${pod_id}.json" &
            bg_pids+=("$!")
        done < <(echo "$pods_json" | jq -c '.[]' 2> /dev/null)
        for bg_pid in "${bg_pids[@]}"; do
            wait "$bg_pid" || true
        done

        # Merge poll results into state file under shared lock (also held by scale.php)
        (
            flock -x 200
            local new_state
            new_state=$(
                python3 - "$poll_dir" "$state_file" "$now" << 'PYEOF'
import json, sys, os

poll_dir, state_file, now = sys.argv[1], sys.argv[2], int(sys.argv[3])

new_pods = []
for fname in os.listdir(poll_dir):
    if not fname.endswith('.json'):
        continue
    try:
        with open(os.path.join(poll_dir, fname)) as f:
            p = json.load(f)
        if p.get('model_id', ''):
            new_pods.append(p)
    except Exception:
        pass

try:
    with open(state_file) as f:
        old_state = json.load(f)
except Exception:
    old_state = {'pods': [], 'last_request_at': 0}

old_by_url = {p['url']: p for p in old_state.get('pods', [])}
merged = []
for p in new_pods:
    old = old_by_url.get(p['url'], {})
    # carry over in_flight; reset to 0 if GPU is idle
    old_in_flight = int(old.get('in_flight', 0))
    in_flight = 0 if p['gpu_util'] == 0 else old_in_flight
    merged.append({
        'url': p['url'],
        'pod_id': p.get('pod_id', ''),
        'model_id': p['model_id'],
        'config_id': p['config_id'],
        'first_seen_at': old.get('first_seen_at', now),
        'gpu_util': p['gpu_util'],
        'in_flight': in_flight,
    })

merged.sort(key=lambda p: p.get('config_id', ''))

print(json.dumps({
    'updated_at': now,
    'last_request_at': old_state.get('last_request_at', 0),
    'count': len(merged),
    'pods': merged,
}, indent=2))
PYEOF
            ) || true
            if [[ -n "$new_state" ]]; then
                printf '%s\n' "$new_state" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
                local pod_count avg_gpu
                pod_count=$(python3 -c "import json,sys; s=json.load(open(sys.argv[1])); print(len(s.get('pods',[])))" "$state_file" 2> /dev/null || echo '?')
                avg_gpu=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
pods = [p for p in s.get('pods', []) if p.get('gpu_util', -1) >= 0]
print(round(sum(p['gpu_util'] for p in pods) / len(pods)) if pods else -1)
" "$state_file" 2> /dev/null || echo '-1')
                log_info "[LB] ${pod_count} pod(s), avg GPU: ${avg_gpu}%"
            fi
        ) 200> "${state_file}.lock"
        rm -rf "$poll_dir"

        # Release .creating locks for pods that have finished their create job (.done marker)
        # and are now registered in pods_status.json. This prevents the health loop from
        # re-triggering a create in the gap between .creating removal and the next poll.
        for done_file in "${creating_dir}/"*.done; do
            [[ -f "$done_file" ]] || continue
            local done_id
            done_id=$(basename "$done_file" .done)
            if python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    ids = {p.get('config_id','') for p in s.get('pods',[])}
    sys.exit(0 if sys.argv[2] in ids else 1)
except Exception:
    sys.exit(1)
" "$state_file" "$done_id" 2>/dev/null; then
                rm -f "${creating_dir}/${done_id}.creating" "${creating_dir}/${done_id}.done"
                log_info "[LB] Pod ${done_id} registered — create lock released."
            fi
        done

        # Scale decision: reach pod-count target
        if [[ -f "$state_file" ]]; then
            # Apply pod-count override if set (written by: scale --pod-count N)
            local scale_override_file="${scale_run_dir}/scale-override"
            if [[ -f "$scale_override_file" ]]; then
                local override_target
                override_target=$(tr -d '[:space:]' < "$scale_override_file")
                if [[ "$override_target" =~ ^[0-9]+$ ]] && [[ "$override_target" -ge 1 ]]; then
                    LB_POD_COUNT="$override_target"
                fi
            fi

            local in_progress
            in_progress=$(ls "${creating_dir}/" 2> /dev/null | grep -c '\.creating$' || true)

            local scale_decision
            scale_decision=$(
                python3 - "$state_file" "$LB_POD_COUNT" "$in_progress" << 'PYEOF'
import json, sys

state_file = sys.argv[1]
pod_count = int(sys.argv[2])
in_progress = int(sys.argv[3])

try:
    with open(state_file) as f:
        state = json.load(f)
except Exception:
    sys.exit(0)

pods = state.get('pods', [])
total = len(pods)

# Scale up: spawn as many as still needed to reach pod_count
needed = pod_count - total - in_progress
if needed > 0:
    print('up:' + str(needed))
    sys.exit(0)

# Scale down: remove one pod at a time (oldest first) until target reached
if in_progress == 0 and total > pod_count:
    candidate = min(pods, key=lambda p: p.get('first_seen_at', 0))
    print('down:' + candidate['config_id'])
    sys.exit(0)
PYEOF
            ) || true

            if [[ "$scale_decision" == up:* ]]; then
                local spawn_count="${scale_decision#up:}"
                # Determine which IDs are already taken (running or being created)
                local next_ids
                next_ids=$(
                    python3 - "$state_file" "$creating_dir" "$spawn_count" << 'PYEOF'
import json, sys, os

try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
except Exception:
    state = {'pods': []}

creating_dir = sys.argv[2]
want = int(sys.argv[3])

existing = {p.get('config_id', '') for p in state.get('pods', [])}
try:
    creating = {f[:-len('.creating')] for f in os.listdir(creating_dir) if f.endswith('.creating')}
except Exception:
    creating = set()
taken = existing | creating

result = []
for i in range(1, 100):
    c = 'lb-' + str(i).zfill(3)
    if c not in taken:
        result.append(c)
        taken.add(c)
    if len(result) >= want:
        break
print(' '.join(result))
PYEOF
                ) || true
                for next_id in $next_ids; do
                    touch "${creating_dir}/${next_id}.creating"
                    log_info "[LB] Scaling up: creating pod ${next_id}..."
                    (
                        create_args=(--id "$next_id" --gpu "$LB_GPU" --hdd "$LB_HDD" --model "$LB_MODEL" --context-length "$LB_CONTEXT_LENGTH" --lmstudio-api-key "$LB_API_KEY")
                        [[ -n "$LB_PARALLEL" ]] && create_args+=(--parallel "$LB_PARALLEL")
                        bash "${PACKAGE_DIR}/runpod.sh" create \
                            "${create_args[@]}" \
                            >> "${scale_run_dir}/scale-up.${next_id}.log" 2>&1
                        # Mark as done so the health loop removes .creating only after
                        # the pod appears in the next poll — avoids a race where
                        # .creating is gone but the pod is not yet in pods_status.json.
                        touch "${creating_dir}/${next_id}.done"
                    ) &
                    echo $! > "${creating_dir}/${next_id}.pid"
                done
            fi

            if [[ "$scale_decision" == down:* ]]; then
                local down_id="${scale_decision#down:}"
                log_info "[LB] Scaling down: deleting pod ${down_id}..."
                (
                    bash "${PACKAGE_DIR}/runpod.sh" delete \
                        --id "$down_id" \
                        >> "${scale_run_dir}/scale-down.log" 2>&1
                ) &
            fi
        fi

        sleep "$LB_CHECK_INTERVAL" || true
    done
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
    scale) cmd_scale "${@:2}" ;;
    _lb_health_loop) _cmd_lb_health_loop "${@:2}" ;;
    *)
        echo "Usage: $0 {init|create|test|delete|status|scale}"
        echo ""
        echo "  init    Copy .env.example and models.yaml to project root (run once after install)"
        echo "  create --id <id> --gpu <gpu> --hdd <hdd> --model <model> --context-length <n> --lmstudio-api-key <key> [--auto-destroy <seconds>]"
        echo "         Check GPU availability, create pod, install LM Studio, configure nginx auth proxy, load model"
        echo "  test quality [--runs <n>]"
        echo "         Run runpod.php per RUNNING pod in parallel with separate logs (default: 1 run per pod)"
        echo "  test quantity [--runs <n>]"
        echo "         Run N parallel browser MCP tests against the load balancer (default: 20)"
        echo "  delete {--all | --id <id>}
         Terminate pod(s) and remove Cloudflare DNS/redirect entries"
        echo "  status  Show current pod status"
        echo "  scale {--start|--stop|--refresh|--pod-count} --gpu <gpu> --hdd <hdd> --model <model> --context-length <n> --lmstudio-api-key <key> [options]"
        echo "         Start/stop pod cluster with a fixed pod count."
        echo "         --refresh: Unload and reload the LLM on all pods (clears KV cache, resets inference queue)."
        echo "         --pod-count <n>: Change the pod count on a running cluster."
        echo "         Options: --pod-count (1) --check-interval (15) --auto-destroy <seconds>"
        echo ""
        exit 1
        ;;
esac
