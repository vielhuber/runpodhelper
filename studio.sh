# Unsloth Studio lifecycle commands.

studio_pods_json() {
    local pods
    pods=$(runpod_rest_api GET '/pods') || return 1
    printf '%s' "$pods" | jq '[.[] | select(.name | startswith("llmpod-studio-"))] | sort_by(.name)'
}

studio_normalize_id() {
    local config_id="$1"
    if [[ -z "$config_id" || ${#config_id} -gt 64 || ! "$config_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Studio ID must start with a letter or number and contain at most 64 letters, numbers, underscores or hyphens." >&2
        return 1
    fi
    if [[ "$config_id" =~ ^[0-9]+$ ]]; then
        config_id=$(printf '%s' "$config_id" | sed 's/^0*//')
        config_id="${config_id:-0}"
        while [[ ${#config_id} -lt 3 ]]; do
            config_id="0${config_id}"
        done
    fi
    config_id="${config_id//_/-}"
    printf '%s' "${config_id,,}"
}

studio_pod_name() {
    local config_id="$1"
    printf 'llmpod-studio-%s' "$(printf '%s' "$config_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//')"
}

studio_config_id() {
    printf '%s' "${1#llmpod-studio-}"
}

studio_state_file() {
    printf '%s/logs/studio/state-%s.json' "$PROJECT_DIR" "$1"
}

studio_secure_state_file() {
    chmod 600 "$1"
}

studio_is_healthy() {
    curl -sf --max-time 2 "http://127.0.0.1:${1}/api/health" 2> /dev/null | grep -q 'Unsloth UI Backend'
}

studio_select_pod() {
    local config_id="${1:-}"
    local pods count
    pods=$(studio_pods_json) || return 1
    if [[ -n "$config_id" ]]; then
        local name
        name=$(studio_pod_name "$config_id")
        printf '%s' "$pods" | jq -c --arg name "$name" 'first(.[] | select(.name == $name)) // empty'
        return
    fi

    count=$(printf '%s' "$pods" | jq 'length')
    if [[ "$count" -eq 1 ]]; then
        printf '%s' "$pods" | jq -c '.[0]'
        return
    fi
    if [[ "$count" -gt 1 ]]; then
        log_error "Multiple Studio pods found. Use --id <id>." >&2
        return 1
    fi
}

studio_artifacts() {
    run_remote "$1" '
find /workspace \
    \( -path "/workspace/cache" -o -path "/workspace/unsloth/studio/llama.cpp" -o -path "*/.cache" -o -path "*/site-packages" -o -path "*/node_modules" \) \
    -prune -o \
    -type f \( -iname "*.gguf" -o -iname "*.safetensors" -o -iname "adapter_config.json" \) \
    -printf "%T@\t%s\t%p\n" 2>/dev/null | sort -nr
' 'no' 2> /dev/null || true
}

studio_stop_tunnel() {
    local state_file tunnel_pid local_port tunnel_process tunnel_command state_tmp
    state_file=$(studio_state_file "$1")
    [[ -f "$state_file" ]] || return 0
    tunnel_pid=$(jq -r '.tunnel_pid // empty' "$state_file" 2> /dev/null || true)
    local_port=$(jq -r '.local_port // empty' "$state_file" 2> /dev/null || true)
    if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2> /dev/null; then
        tunnel_process=$(ps -p "$tunnel_pid" -o comm= 2> /dev/null || true)
        tunnel_command=$(ps -p "$tunnel_pid" -o args= 2> /dev/null || true)
        if [[ -n "$local_port" && "$tunnel_process" == 'ssh' && "$tunnel_command" == *"-L ${local_port}:127.0.0.1:8888"* ]]; then
            kill "$tunnel_pid" 2> /dev/null || true
        fi
    fi
    state_tmp="${state_file}.tmp"
    jq 'del(.tunnel_pid, .local_port)' "$state_file" > "$state_tmp" && mv "$state_tmp" "$state_file" || {
        rm -f "$state_tmp"
        log_error "Could not update Studio state file ${state_file}."
        return 1
    }
    studio_secure_state_file "$state_file"
}

studio_ensure_tunnel() {
    local pod_id="$1" config_id="$2"
    local state_file existing_pid existing_port existing_process existing_command
    state_file=$(studio_state_file "$config_id")
    mkdir -p "$(dirname "$state_file")"

    if [[ -f "$state_file" ]]; then
        existing_pid=$(jq -r '.tunnel_pid // empty' "$state_file" 2> /dev/null || true)
        existing_port=$(jq -r '.local_port // empty' "$state_file" 2> /dev/null || true)
        existing_process=$(ps -p "$existing_pid" -o comm= 2> /dev/null || true)
        existing_command=$(ps -p "$existing_pid" -o args= 2> /dev/null || true)
        if [[ -n "$existing_pid" && -n "$existing_port" ]] && kill -0 "$existing_pid" 2> /dev/null \
            && [[ "$existing_process" == 'ssh' && "$existing_command" == *"-L ${existing_port}:127.0.0.1:8888"* ]] \
            && studio_is_healthy "$existing_port"; then
            printf '%s' "$existing_port"
            return 0
        fi
    fi
    studio_stop_tunnel "$config_id"

    local ssh_info host ssh_port local_port
    ssh_info=$(pod_ssh_details "$pod_id") || return 1
    host=$(printf '%s' "$ssh_info" | awk '{print $1}')
    ssh_port=$(printf '%s' "$ssh_info" | awk '{print $2}')
    local_port=$(
        python3 - << 'PY'
import socket

for port in range(8888, 8909):
    with socket.socket() as sock:
        try:
            sock.bind(('127.0.0.1', port))
        except OSError:
            continue
        print(port)
        break
PY
    )
    [[ -n "$local_port" ]] || {
        log_error "No free local port between 8888 and 8908." >&2
        return 1
    }

    local tunnel_log="${PROJECT_DIR}/logs/studio/tunnel-${config_id}.log"
    if ! ssh -f -N \
        -o StrictHostKeyChecking=no \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -i "$SSH_KEY" \
        -p "$ssh_port" \
        -L "${local_port}:127.0.0.1:8888" \
        "root@${host}" > "$tunnel_log" 2>&1; then
        log_error "Studio tunnel failed. See ${tunnel_log}." >&2
        return 1
    fi
    local tunnel_pid
    tunnel_pid=$(ps -eo pid=,comm=,args= | awk -v forward="-L ${local_port}:127.0.0.1:8888" -v target="root@${host}" \
        '$2 == "ssh" && index($0, forward) && index($0, target) { print $1 }' | tail -1)
    [[ -n "$tunnel_pid" ]] || {
        log_error "Studio tunnel started, but its process could not be identified." >&2
        return 1
    }

    local ready=0
    for _ in $(seq 1 30); do
        if studio_is_healthy "$local_port"; then
            ready=1
            break
        fi
        kill -0 "$tunnel_pid" 2> /dev/null || break
        sleep 1
    done
    if [[ "$ready" -ne 1 ]]; then
        kill "$tunnel_pid" 2> /dev/null || true
        log_error "Studio tunnel failed. See ${tunnel_log}." >&2
        return 1
    fi

    if [[ -f "$state_file" ]]; then
        local state_tmp="${state_file}.tmp"
        jq --argjson pid "$tunnel_pid" --argjson port "$local_port" \
            '.tunnel_pid = $pid | .local_port = $port' "$state_file" > "$state_tmp" \
            && mv "$state_tmp" "$state_file" || {
            kill "$tunnel_pid" 2> /dev/null || true
            rm -f "$state_tmp"
            log_error "Could not update Studio state file ${state_file}." >&2
            return 1
        }
        studio_secure_state_file "$state_file"
    else
        umask 077
        jq -n --arg id "$config_id" --arg pod_id "$pod_id" --arg pod_name "$(studio_pod_name "$config_id")" \
            --argjson pid "$tunnel_pid" --argjson port "$local_port" \
            '{id: $id, pod_id: $pod_id, pod_name: $pod_name, mode: "studio", tunnel_pid: $pid, local_port: $port}' \
            > "$state_file"
        studio_secure_state_file "$state_file"
    fi
    printf '%s' "$local_port"
}

studio_open_browser() {
    local url="$1"
    if command -v wslview > /dev/null 2>&1; then
        setsid -f wslview "$url" > /dev/null 2>&1 < /dev/null
        return
    fi
    if grep -qi microsoft /proc/version 2> /dev/null && command -v powershell.exe > /dev/null 2>&1; then
        setsid -f powershell.exe -NoProfile -Command "Start-Process '${url}'" > /dev/null 2>&1 < /dev/null
        return
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xdg-open > /dev/null 2>&1; then
        setsid -f xdg-open "$url" > /dev/null 2>&1 < /dev/null
    fi
}

studio_browser_url() {
    local base_url="$1" password="${2:-}"
    if [[ -z "$password" ]]; then
        printf '%s' "$base_url"
        return
    fi
    local encoded_password
    encoded_password=$(printf '%s' "$password" | jq -sRr @uri)
    printf '%s/runpodhelper-login.html#password=%s' "$base_url" "$encoded_password"
}

studio_derive_password() {
    printf 'runpodhelper-studio:%s' "$1" \
        | openssl dgst -sha256 -hmac "$RUNPOD_API_KEY" -binary \
        | od -An -tx1 \
        | tr -d ' \n'
}

studio_configure_hf_token() {
    local pod_id="$1" token="${HF_TOKEN:-}" quoted_token
    [[ -n "$token" ]] || return 0
    quoted_token=$(printf '%q' "$token")
    run_remote "$pod_id" "
set -euo pipefail
mkdir -p /root/.config
token=${quoted_token}
secret_file=/root/.config/runpod-unsloth-studio-secrets.env
current_token=''
if [[ -f \"\${secret_file}\" ]]; then
    source \"\${secret_file}\"
    current_token=\"\${HF_TOKEN:-}\"
fi
[[ \"\${current_token}\" == \"\${token}\" ]] && exit 0
printf 'export HF_TOKEN=%q\\n' \"\${token}\" > \"\${secret_file}\"
chmod 600 \"\${secret_file}\"
pkill -f '[u]nsloth studio' >/dev/null 2>&1 || true
for _ in \$(seq 1 30); do
    pgrep -f '[u]nsloth studio' >/dev/null 2>&1 || break
    sleep 1
done
STUDIO_AUTOSTART=/usr/local/bin/runpod-unsloth-studio-autostart.sh
[[ -x \"\${STUDIO_AUTOSTART}\" ]] || STUDIO_AUTOSTART=/workspace/unsloth/runpod-unsloth-studio-autostart.sh
\"\${STUDIO_AUTOSTART}\"
" 'no'
}

studio_check_hub() {
    local pod_id="$1"
    if run_remote "$pod_id" '
[[ -f /root/.config/runpod-unsloth-studio-secrets.env ]] && source /root/.config/runpod-unsloth-studio-secrets.env
headers=()
[[ -n "${HF_TOKEN:-}" ]] && headers=(-H "Authorization: Bearer ${HF_TOKEN}")
curl -fsS --connect-timeout 5 --max-time 15 \
    "${headers[@]}" \
    -o /dev/null "https://huggingface.co/api/models?limit=1"
' 'no' > /dev/null 2>&1; then
        log_ok "Hugging Face Hub is reachable."
        return 0
    fi
    if [[ -n "${HF_TOKEN:-}" ]]; then
        log_warn "Hugging Face Hub is currently unreachable even with HF_TOKEN. This is an external network or Hub problem."
        return 0
    fi
    log_warn "Hugging Face Hub is unreachable anonymously. Add a read token as HF_TOKEN to .env and run studio up again."
}

studio_prepare_model() {
    local pod_id="$1" model="$2" context_length="$3" studio_password
    [[ -n "$model" ]] || return 0
    studio_password=$(studio_derive_password "$pod_id")

    local quoted_model
    quoted_model=$(printf '%q' "$model")
    log_info "Preparing trainable model ${model}..."
    if ! run_remote "$pod_id" "
set -euo pipefail
source /workspace/unsloth/runpod-unsloth-studio.env
[[ -f /root/.config/runpod-unsloth-studio-secrets.env ]] && source /root/.config/runpod-unsloth-studio-secrets.env
export UNSLOTH_STUDIO_HOME HF_HOME XDG_CACHE_HOME HF_TOKEN
export HF_XET_HIGH_PERFORMANCE=1
export RUNPODHELPER_MODEL=${quoted_model}
STUDIO_PYTHON=\"\$(dirname \"\${UNSLOTH_BIN}\")/python\"
\"\${STUDIO_PYTHON}\" - <<'PY' &
import os

from huggingface_hub import snapshot_download

snapshot_download(
    repo_id=os.environ['RUNPODHELPER_MODEL'],
    token=os.environ.get('HF_TOKEN') or None,
)
PY
download_pid=\$!
trap 'kill "\${download_pid}" 2>/dev/null || true' EXIT
cache_name=\"\${RUNPODHELPER_MODEL/\//--}\"
cache_dir=\"\${HF_HOME}/hub/models--\${cache_name}\"
download_started_at=\${SECONDS}
while kill -0 \"\${download_pid}\" 2>/dev/null; do
    downloaded_bytes=\$(du -s -B1 \"\${cache_dir}\" 2>/dev/null | awk '{print \$1}' || true)
    downloaded_size=\"pending\"
    if [[ -n \"\${downloaded_bytes}\" && \"\${downloaded_bytes}\" -ge 10000000 ]]; then
        downloaded_size=\$(awk -v bytes=\"\${downloaded_bytes}\" 'BEGIN {printf \"%.1f GB\", bytes / 1000000000}')
    fi
    echo \"[DOWNLOAD] Active for \$((SECONDS - download_started_at))s; completed cache: \${downloaded_size}\"
    sleep 15
done
download_status=0
wait \"\${download_pid}\" || download_status=\$?
exit \"\${download_status}\"
" 'no'; then
        log_error "Trainable model ${model} could not be downloaded."
        return 1
    fi
    log_ok "Trainable model is available in Studio: ${model}"

    local quoted_context_length quoted_password
    quoted_context_length=$(printf '%q' "$context_length")
    quoted_password=$(printf '%q' "$studio_password")
    log_info "Ensuring ${model} is loaded in Studio with 4-bit quantization..."
    if run_remote "$pod_id" "
set -euo pipefail
source /workspace/unsloth/runpod-unsloth-studio.env
export RUNPODHELPER_MODEL=${quoted_model}
export RUNPODHELPER_CONTEXT_LENGTH=${quoted_context_length}
export RUNPODHELPER_STUDIO_PASSWORD=${quoted_password}
STUDIO_PYTHON=\"\$(dirname \"\${UNSLOTH_BIN}\")/python\"
\"\${STUDIO_PYTHON}\" - <<'PY'
import json
import os
import urllib.request


def post(path, payload, token=None, timeout=900):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = urllib.request.Request(
        f'http://127.0.0.1:8888{path}',
        data=json.dumps(payload).encode(),
        headers=headers,
        method='POST',
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


login = post('/api/auth/login', {
    'username': 'unsloth',
    'password': os.environ['RUNPODHELPER_STUDIO_PASSWORD'],
})
access_token = login['access_token']
status_request = urllib.request.Request(
    'http://127.0.0.1:8888/api/inference/status',
    headers={'Authorization': f'Bearer {access_token}'},
)
with urllib.request.urlopen(status_request, timeout=30) as response:
    status = json.load(response)
if status.get('active_model') == os.environ['RUNPODHELPER_MODEL'] and not status.get('loading'):
    raise SystemExit(0)
post('/api/inference/load', {
    'model_path': os.environ['RUNPODHELPER_MODEL'],
    'hf_token': None,
    'max_seq_length': int(os.environ['RUNPODHELPER_CONTEXT_LENGTH']),
    'load_in_4bit': True,
    'is_lora': False,
    'gguf_variant': None,
    'trust_remote_code': False,
}, token=access_token)
PY
" 'no'; then
        log_ok "Model loaded in Studio: ${model}"
        return 0
    fi
    log_warn "The model is installed and selectable under Train > Local Model, but automatic loading failed. Select it there manually."
}

studio_print_next_steps() {
    local config_id="$1" config_count="$2" local_port="$3" studio_password="${4:-}"
    local id_option=''
    if [[ "$config_count" -gt 1 ]]; then
        id_option=" --id ${config_id}"
    fi

    echo
    echo "────────────────────────────────────────────────────"
    echo "  Unsloth Studio is ready"
    echo "────────────────────────────────────────────────────"
    printf '  %-22s %s\n' 'Open Studio:' "http://127.0.0.1:${local_port}"
    if [[ -n "$studio_password" ]]; then
        printf '  %-22s %s\n' 'Username:' 'unsloth'
        printf '  %-22s %s\n' 'Password:' "$studio_password"
    fi
    printf '  %-22s %s\n' 'Check status:' "$0 studio status${id_option}"
    printf '  %-22s %s\n' 'Deploy exported GGUF:' "$0 studio deploy${id_option}"
    echo "  Download artifacts before down; it deletes all remote data."
    printf '  %-22s %s\n' 'Delete pod + data:' "$0 studio down${id_option}"
    echo "────────────────────────────────────────────────────"
    echo
}

studio_mark_studio_state() {
    local state_file state_tmp
    state_file=$(studio_state_file "$1")
    [[ -f "$state_file" ]] || return 0
    state_tmp="${state_file}.tmp"
    jq '.mode = "studio" | del(.artifact, .model_id, .deployed_at)' "$state_file" > "$state_tmp" && mv "$state_tmp" "$state_file" || {
        rm -f "$state_tmp"
        log_error "Could not update Studio state file ${state_file}."
        return 1
    }
    studio_secure_state_file "$state_file"
}

studio_activate_studio() {
    local pod_id="$1" config_id="$2"
    run_remote "$pod_id" '
pkill -f "[l]lama-server" >/dev/null 2>&1 || true
pkill -f "[r]unpod-llamacpp-dispatcher.py" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    pgrep -f "[l]lama-server|[r]unpod-llamacpp-dispatcher.py" >/dev/null 2>&1 || break
    sleep 1
done
pkill -9 -f "[l]lama-server" >/dev/null 2>&1 || true
pkill -9 -f "[r]unpod-llamacpp-dispatcher.py" >/dev/null 2>&1 || true
rm -f /root/.config/runpod-llamacpp-deployment.env
STUDIO_AUTOSTART=/usr/local/bin/runpod-unsloth-studio-autostart.sh
[[ -x "${STUDIO_AUTOSTART}" ]] || STUDIO_AUTOSTART=/workspace/unsloth/runpod-unsloth-studio-autostart.sh
[[ -x "${STUDIO_AUTOSTART}" ]] || exit 1
"${STUDIO_AUTOSTART}"
' 'no' || return 1

    local local_port state_file studio_password browser_url managed_auth
    local_port=$(studio_ensure_tunnel "$pod_id" "$config_id") || return 1
    studio_mark_studio_state "$config_id" || return 1
    state_file=$(studio_state_file "$config_id")
    managed_auth=$(jq -r '.managed_auth // false' "$state_file")
    studio_password=''
    [[ "$managed_auth" == 'true' ]] && studio_password=$(studio_derive_password "$pod_id")
    browser_url=$(studio_browser_url "http://127.0.0.1:${local_port}" "$studio_password")
    log_ok "Unsloth Studio is ready: http://127.0.0.1:${local_port}"
    studio_open_browser "$browser_url"
}

studio_read_configs() {
    local config_file="$1"
    [[ -f "$config_file" ]] || {
        log_error "Studio config not found: ${config_file}"
        return 1
    }

    python3 - "$config_file" << 'PY'
import json
import re
import sys
import yaml

with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
if not isinstance(document, dict):
    sys.exit('[ERROR] Studio config must be a YAML mapping.')
if isinstance(document.get('studios'), list):
    studios = document['studios']
elif isinstance(document.get('studio'), dict):
    studios = [document['studio']]
else:
    sys.exit('[ERROR] Config must contain a top-level "studios" list.')
if not studios:
    sys.exit('[ERROR] studios must contain at least one entry.')

allowed_keys = {
    'gpu', 'datacenter', 'hdd', 'volume',
    'image', 'type', 'api_key', 'context_length', 'model'
}
normalized = []
for index, studio in enumerate(studios, start=1):
    if not isinstance(studio, dict):
        sys.exit(f'[ERROR] studios entry {index} must be a mapping.')
    unknown_keys = sorted(set(studio) - allowed_keys)
    if unknown_keys:
        sys.exit('[ERROR] Unknown studio setting(s): ' + ', '.join(unknown_keys))
    config_id = str(index).zfill(3)
    datacenter = str(studio.get('datacenter') or '')
    if datacenter and not re.fullmatch(r'[A-Z0-9-]+', datacenter):
        sys.exit('[ERROR] studio.datacenter must be a valid RunPod data center ID when provided.')
    image = str(studio.get('image') or '')
    if not image:
        sys.exit('[ERROR] studio.image is required.')
    deployment_type = str(studio.get('type') or '')
    if deployment_type != 'llamacpp':
        sys.exit('[ERROR] studio.type must be llamacpp.')
    api_key = str(studio.get('api_key') or '')
    if not api_key:
        sys.exit('[ERROR] studio.api_key is required.')
    model = str(studio.get('model') or '')
    if model and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*', model):
        sys.exit('[ERROR] studio.model must be a Hugging Face repository in owner/model format.')
    if 'gguf' in model.lower():
        sys.exit('[ERROR] studio.model must be a trainable Transformers/Safetensors model, not a GGUF repository.')
    try:
        hdd = int(studio.get('hdd') or 40)
        volume = int(studio.get('volume') or 200)
        context_length = int(studio.get('context_length') or 8192)
    except (TypeError, ValueError):
        sys.exit('[ERROR] studio.hdd, studio.volume and studio.context_length must be integers.')
    if hdd < 20 or volume < 50 or context_length < 512:
        sys.exit('[ERROR] studio.hdd must be >= 20, studio.volume >= 50 and studio.context_length >= 512.')
    normalized.append({
        'id': config_id,
        'gpu': str(studio.get('gpu') or 'RTX 4090'),
        'datacenter': datacenter,
        'hdd': hdd,
        'volume': volume,
        'image': image,
        'type': deployment_type,
        'api_key': api_key,
        'context_length': context_length,
        'model': model,
    })
print(json.dumps(normalized))
PY
}

cmd_studio_up() {
    local config_file='studio.yaml' config_id='' dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                [[ $# -ge 2 ]] || {
                    log_error "--config requires a value."
                    return 1
                }
                config_file="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            --id)
                [[ $# -ge 2 ]] || {
                    log_error "--id requires a value."
                    return 1
                }
                config_id="$2"
                shift 2
                ;;
            *)
                log_error "Unknown Studio up argument: $1"
                return 1
                ;;
        esac
    done
    [[ -f "$config_file" ]] || {
        log_error "Studio config not found: ${config_file}"
        return 1
    }
    config_file=$(readlink -f "$config_file")
    local configs config
    configs=$(studio_read_configs "$config_file") || return 1
    if [[ -n "$config_id" ]]; then
        config_id=$(studio_normalize_id "$config_id") || return 1
        config=$(printf '%s' "$configs" | jq -c --arg id "$config_id" 'first(.[] | select(.id == $id)) // empty')
        [[ -n "$config" ]] || {
            log_error "Studio config ID not found: ${config_id}"
            return 1
        }
    elif [[ "$(printf '%s' "$configs" | jq 'length')" -eq 1 ]]; then
        config=$(printf '%s' "$configs" | jq -c '.[0]')
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        log_ok "Studio configuration is valid."
        printf '%s\n' "${config:-$configs}" | jq .
        return 0
    fi

    [[ -n "$config" ]] || {
        log_error "Multiple Studio configurations found. Use --id <id>."
        return 1
    }

    local gpu datacenter hdd volume image deployment_type api_key context_length model pod_name
    config_id=$(printf '%s' "$config" | jq -r '.id')
    gpu=$(printf '%s' "$config" | jq -r '.gpu')
    datacenter=$(printf '%s' "$config" | jq -r '.datacenter')
    hdd=$(printf '%s' "$config" | jq -r '.hdd')
    volume=$(printf '%s' "$config" | jq -r '.volume')
    image=$(printf '%s' "$config" | jq -r '.image')
    deployment_type=$(printf '%s' "$config" | jq -r '.type')
    api_key=$(printf '%s' "$config" | jq -r '.api_key')
    context_length=$(printf '%s' "$config" | jq -r '.context_length')
    model=$(printf '%s' "$config" | jq -r '.model')
    pod_name=$(studio_pod_name "$config_id")

    local existing_pod
    existing_pod=$(studio_pods_json | jq -c --arg name "$pod_name" 'first(.[] | select(.name == $name)) // empty')
    if [[ -n "$existing_pod" ]]; then
        log_warn "Studio pod ${pod_name} already exists."
        local existing_pod_id existing_pod_status existing_pod_details existing_volumes existing_volume existing_network_volume_id existing_volume_size existing_volume_datacenter existing_image existing_storage
        local state_file state_tmp
        existing_pod_id=$(printf '%s' "$existing_pod" | jq -r '.id')
        existing_pod_status=$(printf '%s' "$existing_pod" | jq -r '.desiredStatus')
        if [[ "$existing_pod_status" != 'RUNNING' ]]; then
            log_error "Existing Studio pod ${pod_name} is ${existing_pod_status}. Run studio down before starting it again."
            return 1
        fi
        existing_pod_details=$(runpod_rest_api GET "/pods/${existing_pod_id}") || return 1
        existing_network_volume_id=$(printf '%s' "$existing_pod_details" | jq -r '.networkVolumeId // .networkVolume.id // empty')
        existing_volume_size=$(printf '%s' "$existing_pod_details" | jq -r '.volumeInGb // empty')
        existing_volume_datacenter=$(printf '%s' "$existing_pod_details" | jq -r '.dataCenterId // .machine.dataCenterId // .machine.dataCenter.id // empty')
        existing_image=$(printf '%s' "$existing_pod_details" | jq -r '.imageName // empty')
        existing_storage='pod_volume'
        if [[ -n "$existing_network_volume_id" ]]; then
            existing_volumes=$(runpod_rest_api GET '/networkvolumes') || return 1
            existing_volume=$(printf '%s' "$existing_volumes" | jq -c --arg id "$existing_network_volume_id" '
                (if type == "array" then . else (.data // []) end)
                | first(.[] | select(.id == $id)) // empty
            ')
            [[ -n "$existing_volume" ]] || {
                log_error "Network volume ${existing_network_volume_id} used by ${pod_name} was not found."
                return 1
            }
            existing_volume_size=$(printf '%s' "$existing_volume" | jq -r '.size // empty')
            existing_volume_datacenter=$(printf '%s' "$existing_volume" | jq -r '.dataCenterId // empty')
            existing_storage='network_volume'
        fi
        [[ (-z "$datacenter" || -z "$existing_volume_datacenter" || "$existing_volume_datacenter" == "$datacenter") && "$existing_volume_size" =~ ^[0-9]+$ && "$existing_volume_size" -ge "$volume" ]] || {
            log_error "Existing Studio pod ${pod_name} does not match the configured data center or minimum volume size."
            return 1
        }
        [[ -n "$existing_volume_datacenter" ]] && datacenter="$existing_volume_datacenter"
        if [[ -n "$existing_image" && "$existing_image" != "$image" ]]; then
            log_error "Existing Studio pod ${pod_name} uses image ${existing_image}, not configured image ${image}."
            return 1
        fi
        studio_configure_hf_token "$existing_pod_id" || return 1
        studio_activate_studio "$existing_pod_id" "$config_id" || return 1
        studio_check_hub "$existing_pod_id"
        studio_prepare_model "$existing_pod_id" "$model" "$context_length" || return 1
        state_file=$(studio_state_file "$config_id")
        state_tmp="${state_file}.tmp"
        jq --arg network_volume_id "$existing_network_volume_id" --arg storage "$existing_storage" --arg datacenter "$datacenter" \
            --arg image "$image" --arg type "$deployment_type" --arg api_key "$api_key" --arg config_file "$config_file" --arg model "$model" \
            --argjson context "$context_length" --argjson volume_size "$existing_volume_size" \
            '.storage = $storage | .volume_size = $volume_size | .datacenter = $datacenter | .image = $image | .type = $type | .api_key = $api_key | .config_file = $config_file | .context_length = $context | .model = $model | if $network_volume_id == "" then del(.volume_id, .volume_name) else .volume_id = $network_volume_id end' \
            "$state_file" > "$state_tmp" && mv "$state_tmp" "$state_file" || {
            rm -f "$state_tmp"
            log_error "Could not update Studio state file ${state_file}."
            return 1
        }
        studio_secure_state_file "$state_file"
        local existing_local_port config_count existing_studio_password
        existing_local_port=$(jq -r '.local_port // empty' "$state_file")
        config_count=$(printf '%s' "$configs" | jq 'length')
        existing_studio_password=''
        if [[ "$(jq -r '.managed_auth // false' "$state_file")" == 'true' ]]; then
            existing_studio_password=$(studio_derive_password "$existing_pod_id")
        fi
        studio_print_next_steps "$config_id" "$config_count" "$existing_local_port" "$existing_studio_password"
        return
    fi

    local resolved_gpu
    resolved_gpu=$(check_gpu_availability "$gpu") || return 1
    load_ssh_pubkey

    local start_command pod_payload
    start_command='set -e; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server; mkdir -p /root/.ssh; chmod 700 /root/.ssh; printf "%s\n" "$MY_SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; ssh-keygen -A; service ssh start; if [[ -f /root/.config/runpod-llamacpp-deployment.env && -x /usr/local/bin/runpod-llamacpp-autostart.sh ]]; then /usr/local/bin/runpod-llamacpp-autostart.sh; elif [[ -x /workspace/unsloth/runpod-unsloth-studio-autostart.sh ]]; then rm -f /root/.config/runpod-llamacpp-deployment.env; /workspace/unsloth/runpod-unsloth-studio-autostart.sh; elif [[ -x /usr/local/bin/runpod-unsloth-studio-autostart.sh ]]; then rm -f /root/.config/runpod-llamacpp-deployment.env; /usr/local/bin/runpod-unsloth-studio-autostart.sh; fi; sleep infinity'

    pod_payload=$(jq -n \
        --arg name "$pod_name" \
        --arg gpu "$resolved_gpu" \
        --arg image "$image" \
        --arg dc "$datacenter" \
        --arg key "$SSH_PUBKEY" \
        --arg start "$start_command" \
        --argjson hdd "$hdd" \
        --argjson volume "$volume" \
        '{
            cloudType: "SECURE",
            computeType: "GPU",
            name: $name,
            gpuCount: 1,
            gpuTypeIds: [$gpu],
            gpuTypePriority: "availability",
            imageName: $image,
            containerDiskInGb: $hdd,
            volumeInGb: $volume,
            volumeMountPath: "/workspace",
            ports: ["22/tcp", "1234/tcp"],
            dockerEntrypoint: ["bash", "-lc"],
            dockerStartCmd: [$start],
            env: {MY_SSH_PUBLIC_KEY: $key}
        }
        | if $dc == "" then . else . + {dataCenterIds: [$dc], dataCenterPriority: "availability"} end')

    local pod_response pod_id max_attempts attempt request_status configuration_rejected
    pod_response=''
    pod_id=''
    if [[ -n "$datacenter" ]]; then
        log_info "Creating Studio pod ${pod_name} with ${resolved_gpu} in ${datacenter} and a ${volume} GB pod volume..."
    else
        log_info "Creating Studio pod ${pod_name} with ${resolved_gpu} and a ${volume} GB pod volume..."
    fi
    max_attempts=10
    configuration_rejected=0
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        request_status=0
        pod_response=$(runpod_rest_api POST '/pods' "$pod_payload") || request_status=$?
        if [[ "$request_status" -eq 0 ]]; then
            pod_id=$(printf '%s' "$pod_response" | jq -r '.id // empty')
            [[ -n "$pod_id" ]] || log_error "RunPod returned no pod ID."
        fi
        if [[ -n "$pod_id" ]]; then
            break
        fi
        if [[ "$request_status" -eq 2 ]]; then
            configuration_rejected=1
            break
        fi
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            log_warn "Pod creation attempt ${attempt}/${max_attempts} failed. Retrying in 5 seconds..."
            sleep 5
        fi
    done
    if [[ "$configuration_rejected" -eq 1 ]]; then
        log_error "RunPod rejected the Studio pod configuration."
        return 1
    fi
    [[ -n "$pod_id" ]] || {
        log_error "RunPod currently has no rentable Secure Cloud capacity for ${resolved_gpu}. Retry later or change studio.gpu."
        return 1
    }
    log_ok "Studio pod created: ${pod_id}"
    wait_for_pod "$pod_id" || {
        runpod_rest_api DELETE "/pods/${pod_id}" > /dev/null 2>&1 || true
        return 1
    }
    if [[ -z "$datacenter" ]]; then
        local created_pod_details
        created_pod_details=$(runpod_rest_api GET "/pods/${pod_id}" 2> /dev/null || true)
        datacenter=$(printf '%s' "$created_pod_details" | jq -r '.dataCenterId // .machine.dataCenterId // .machine.dataCenter.id // empty')
    fi
    pod_ssh_details "$pod_id" > /dev/null || {
        runpod_rest_api DELETE "/pods/${pod_id}" > /dev/null 2>&1 || true
        return 1
    }

    local bootstrap_script
    bootstrap_script=$(
        cat << 'BOOTSTRAP'
set -euo pipefail
export UNSLOTH_STUDIO_HOME=/workspace/unsloth/studio
export HF_HOME=/workspace/cache/huggingface
export XDG_CACHE_HOME=/workspace/cache
export PATH="${HOME}/.local/bin:${PATH}"
STUDIO_PORT=8888

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl git cmake build-essential libcurl4-openssl-dev python3 python3-venv
mkdir -p "${UNSLOTH_STUDIO_HOME}" "${HF_HOME}" /workspace/datasets /workspace/checkpoints /workspace/adapters /workspace/merged /workspace/exports

UNSLOTH_BIN=$(find "${UNSLOTH_STUDIO_HOME}" -path '*/bin/unsloth' -type f -executable 2>/dev/null | head -1 || true)
if [[ -z "${UNSLOTH_BIN}" ]]; then
    echo "[SETUP] Installing Unsloth Studio..."
    curl -fsSL https://unsloth.ai/install.sh -o /tmp/unsloth-install.sh
    UNSLOTH_SKIP_AUTOSTART=1 UNSLOTH_VERBOSE=1 UV_HTTP_TIMEOUT=900 sh /tmp/unsloth-install.sh &
    install_pid=$!
    trap 'kill "${install_pid}" 2>/dev/null || true' EXIT
    install_started_at=${SECONDS}
    while kill -0 "${install_pid}" 2>/dev/null; do
        installed_size=$(du -sh "${UNSLOTH_STUDIO_HOME}" 2>/dev/null | awk '{print $1}' || true)
        download_cache_size=$(du -sh "${XDG_CACHE_HOME}/uv" 2>/dev/null | awk '{print $1}' || true)
        echo "[SETUP] Installation active for $((SECONDS - install_started_at))s; downloaded: ${download_cache_size:-pending}; installed: ${installed_size:-pending}"
        sleep 15
    done
    install_status=0
    wait "${install_pid}" || install_status=$?
    trap - EXIT
    rm -f /tmp/unsloth-install.sh
    [[ "${install_status}" -eq 0 ]] || exit "${install_status}"
    UNSLOTH_BIN=$(command -v unsloth || find "${UNSLOTH_STUDIO_HOME}" -path '*/bin/unsloth' -type f -executable 2>/dev/null | head -1 || true)
fi
[[ -n "${UNSLOTH_BIN}" && -x "${UNSLOTH_BIN}" ]] || exit 1

if pgrep -f "[u]nsloth studio" > /dev/null; then
    "${UNSLOTH_BIN}" studio stop > /dev/null 2>&1 || true
    pkill -f "[u]nsloth studio" > /dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -f "[u]nsloth studio" > /dev/null 2>&1 || break
        sleep 1
    done
fi

STUDIO_PYTHON="$(dirname "${UNSLOTH_BIN}")/python"
[[ -x "${STUDIO_PYTHON}" ]] || exit 1

LLAMA_INSTALLER=$(find "${UNSLOTH_STUDIO_HOME}" -path '*/site-packages/studio/install_llama_prebuilt.py' -type f | head -1 || true)
if [[ -n "${LLAMA_INSTALLER}" ]]; then
    STUDIO_BACKEND="$(dirname "${LLAMA_INSTALLER}")/backend"
    LATEST_LLAMA_RELEASE=$(
        cd "${STUDIO_BACKEND}"
        "${STUDIO_PYTHON}" -c 'from utils.llama_cpp_update import get_update_status; status = get_update_status(force_refresh=True); print(status.get("latest_tag") if status.get("update_available") else "")' 2>/dev/null || true
    )
    if [[ "${LATEST_LLAMA_RELEASE}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "[SETUP] Updating llama.cpp to ${LATEST_LLAMA_RELEASE}..."
        "${STUDIO_PYTHON}" "${LLAMA_INSTALLER}" \
            --install-dir "${UNSLOTH_STUDIO_HOME}/llama.cpp" \
            --llama-tag latest \
            --published-repo unslothai/llama.cpp \
            --published-release-tag "${LATEST_LLAMA_RELEASE}"
    fi
fi

mkdir -p /root/.config /workspace/unsloth
printf 'UNSLOTH_STUDIO_HOME=%q\nHF_HOME=%q\nXDG_CACHE_HOME=%q\nSTUDIO_PORT=%q\nUNSLOTH_BIN=%q\n' \
    "${UNSLOTH_STUDIO_HOME}" "${HF_HOME}" "${XDG_CACHE_HOME}" "${STUDIO_PORT}" "${UNSLOTH_BIN}" \
    > /workspace/unsloth/runpod-unsloth-studio.env
ln -sf /workspace/unsloth/runpod-unsloth-studio.env /root/.config/runpod-unsloth-studio.env

cat > /workspace/unsloth/runpod-unsloth-studio-autostart.sh <<'AUTOSTART'
#!/usr/bin/env bash
set -euo pipefail
source /workspace/unsloth/runpod-unsloth-studio.env
[[ -f /root/.config/runpod-unsloth-studio-secrets.env ]] && source /root/.config/runpod-unsloth-studio-secrets.env
export UNSLOTH_STUDIO_HOME HF_HOME XDG_CACHE_HOME
export HF_TOKEN
export HF_XET_HIGH_PERFORMANCE=1
export PATH="${HOME}/.local/bin:${PATH}"
studio_is_healthy() {
    curl -sf --max-time 2 "http://127.0.0.1:${STUDIO_PORT}/api/health" 2>/dev/null | grep -q 'Unsloth UI Backend'
}
studio_is_healthy && exit 0
if pgrep -f "[u]nsloth studio" > /dev/null; then
    for _ in $(seq 1 180); do
        studio_is_healthy && exit 0
        sleep 2
    done
    exit 1
fi
nohup "${UNSLOTH_BIN}" studio -p "${STUDIO_PORT}" > /var/log/unsloth-studio.log 2>&1 &
for _ in $(seq 1 180); do
    studio_is_healthy && exit 0
    sleep 2
done
cat /var/log/unsloth-studio.log || true
exit 1
AUTOSTART
chmod +x /workspace/unsloth/runpod-unsloth-studio-autostart.sh
ln -sf /workspace/unsloth/runpod-unsloth-studio-autostart.sh /usr/local/bin/runpod-unsloth-studio-autostart.sh

FRONTEND_INDEX=$(find "${UNSLOTH_STUDIO_HOME}" -path "*/frontend/dist/index.html" -type f | head -1)
[[ -n "${FRONTEND_INDEX}" ]] || exit 1
FRONTEND_DIR=$(dirname "${FRONTEND_INDEX}")
cat > "${FRONTEND_DIR}/runpodhelper-login.html" <<'LOGIN_HTML'
<!doctype html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Opening Unsloth Studio</title>
</head>
<body>
    <p id="status">Opening Unsloth Studio...</p>
    <script type="module" src="/runpodhelper-login.js"></script>
</body>
</html>
LOGIN_HTML
cat > "${FRONTEND_DIR}/runpodhelper-login.js" <<'LOGIN_JS'
let $status = document.querySelector('#status');
let parameters = new URLSearchParams(window.location.hash.slice(1));
let password = parameters.get('password');
window.history.replaceState(null, '', '/runpodhelper-login.html');
if (!password) {
    $status.textContent = 'Automatic login information is missing.';
} else {
    try {
        let response = await fetch('/api/auth/login', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({username: 'unsloth', password})
        });
        if (!response.ok) {
            throw new Error('Automatic login failed.');
        }
        let tokens = await response.json();
        localStorage.setItem('unsloth_auth_token', tokens.access_token);
        localStorage.setItem('unsloth_auth_refresh_token', tokens.refresh_token);
        localStorage.removeItem('unsloth_auth_must_change_password');
        window.location.replace('/chat');
    } catch {
        window.location.replace('/login');
    }
}
LOGIN_JS
/usr/local/bin/runpod-unsloth-studio-autostart.sh
BOOTSTRAP
    )

    local studio_password
    studio_password=$(studio_derive_password "$pod_id")
    local bootstrap_command
    bootstrap_command="export UNSLOTH_STUDIO_PASSWORD=$(printf '%q' "$studio_password"); ${bootstrap_script}"
    log_info "Installing and starting Unsloth Studio..."
    if ! run_remote "$pod_id" "$bootstrap_command"; then
        log_error "Studio setup failed. The pod and its temporary data are deleted."
        runpod_rest_api DELETE "/pods/${pod_id}" > /dev/null 2>&1 || true
        return 1
    fi
    studio_configure_hf_token "$pod_id" || return 1
    studio_check_hub "$pod_id"
    studio_prepare_model "$pod_id" "$model" "$context_length" || return 1

    local state_file cost_per_hour
    state_file=$(studio_state_file "$config_id")
    cost_per_hour=$(printf '%s' "$pod_response" | jq -r '.adjustedCostPerHr // .costPerHr // empty')
    mkdir -p "$(dirname "$state_file")"
    umask 077
    jq -n \
        --arg id "$config_id" --arg pod_id "$pod_id" --arg pod_name "$pod_name" \
        --arg datacenter "$datacenter" \
        --arg gpu "$resolved_gpu" --arg image "$image" --arg type "$deployment_type" --arg api_key "$api_key" \
        --arg config_file "$config_file" --arg cost "$cost_per_hour" --arg model "$model" \
        --argjson context "$context_length" --argjson volume_size "$volume" \
        '{id: $id, pod_id: $pod_id, pod_name: $pod_name, storage: "pod_volume", volume_size: $volume_size, datacenter: $datacenter, gpu: $gpu, image: $image, type: $type, api_key: $api_key, config_file: $config_file, cost_per_hour: $cost, context_length: $context, model: $model, managed_auth: true, mode: "studio", created_at: (now | todate)}' \
        > "$state_file"
    studio_secure_state_file "$state_file"

    local local_port
    local_port=$(studio_ensure_tunnel "$pod_id" "$config_id") || {
        log_error "Studio is running on pod ${pod_id}, but the local tunnel failed. Use studio status to retry or studio down to terminate it."
        return 1
    }
    log_ok "Unsloth Studio is ready: http://127.0.0.1:${local_port}"
    log_info "Upload data and export GGUF, LoRA or Safetensors directly in Studio."
    log_info "Everything persists on the ${volume} GB pod volume until studio down."

    local browser_url
    browser_url=$(studio_browser_url "http://127.0.0.1:${local_port}" "$studio_password")
    studio_open_browser "$browser_url"
    local config_count
    config_count=$(printf '%s' "$configs" | jq 'length')
    studio_print_next_steps "$config_id" "$config_count" "$local_port" "$studio_password"
}

cmd_studio_status() {
    local config_id=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)
                [[ $# -ge 2 ]] || {
                    log_error "--id requires a value."
                    return 1
                }
                config_id="$2"
                shift 2
                ;;
            *)
                log_error "Unknown Studio status argument: $1"
                return 1
                ;;
        esac
    done
    if [[ -n "$config_id" ]]; then
        config_id=$(studio_normalize_id "$config_id") || return 1
    fi

    local pod
    pod=$(studio_select_pod "$config_id") || return 1
    if [[ -z "$pod" ]]; then
        if [[ -n "$config_id" && -f "$(studio_state_file "$config_id")" ]]; then
            local retained_network_volume
            retained_network_volume=$(jq -r '.volume_id // empty' "$(studio_state_file "$config_id")")
            if [[ -n "$retained_network_volume" ]]; then
                log_warn "Studio pod ${config_id} is not running. Legacy network volume ${retained_network_volume} is retained."
                return
            fi
            log_warn "Studio pod ${config_id} is not running. Its pod volume is no longer available after termination."
            return
        fi
        log_warn "No Studio pod found."
        return
    fi

    local pod_id pod_name pod_status_value gpu mode artifacts state_file storage
    pod_id=$(printf '%s' "$pod" | jq -r '.id')
    pod_name=$(printf '%s' "$pod" | jq -r '.name')
    pod_status_value=$(printf '%s' "$pod" | jq -r '.desiredStatus')
    gpu=$(printf '%s' "$pod" | jq -r '.machine.gpuDisplayName // "unknown"')
    config_id=$(studio_config_id "$pod_name")
    state_file=$(studio_state_file "$config_id")
    storage='unknown'
    if [[ -f "$state_file" ]]; then
        storage=$(jq -r 'if .storage == "pod_volume" then ((.volume_size | tostring) + " GB pod volume") elif .volume_id then ("network volume " + .volume_id) else "unknown" end' "$state_file")
        [[ "$gpu" == 'unknown' ]] && gpu=$(jq -r '.gpu // "unknown"' "$state_file")
    fi

    echo "Studio ${config_id}: ${pod_status_value}"
    echo "  Pod:       ${pod_id}"
    echo "  GPU:       ${gpu}"
    echo "  Storage:   ${storage}"
    if [[ "$pod_status_value" != 'RUNNING' ]]; then
        return
    fi

    mode=$(run_remote "$pod_id" 'if [[ -f /root/.config/runpod-llamacpp-deployment.env && -x /usr/local/bin/runpod-llamacpp-autostart.sh ]]; then echo deploy; else echo studio; fi' 'no' 2> /dev/null | tr -d '[:space:]' || echo studio)
    echo "  Mode:      ${mode}"

    local gpu_utilization
    gpu_utilization=$(run_remote "$pod_id" 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1' 'no' 2> /dev/null | tr -d '[:space:]' || true)
    [[ -n "$gpu_utilization" ]] && echo "  GPU load:  ${gpu_utilization}%"

    if [[ "$mode" == 'studio' ]]; then
        run_remote "$pod_id" 'STUDIO_AUTOSTART=/usr/local/bin/runpod-unsloth-studio-autostart.sh; [[ -x "${STUDIO_AUTOSTART}" ]] || STUDIO_AUTOSTART=/workspace/unsloth/runpod-unsloth-studio-autostart.sh; "${STUDIO_AUTOSTART}"' 'no' > /dev/null || {
            log_warn "  Studio:    could not be started"
            return 1
        }
        local local_port
        local_port=$(studio_ensure_tunnel "$pod_id" "$config_id") || return 1
        studio_mark_studio_state "$config_id" || return 1
        log_ok "  Studio:    http://127.0.0.1:${local_port}"
    else
        local endpoint api_key http_code
        endpoint=$(pod_lmstudio_url "$pod_id" 10 || true)
        api_key=''
        [[ -f "$state_file" ]] && api_key=$(jq -r '.api_key // empty' "$state_file")
        http_code=''
        if [[ -n "$endpoint" && -n "$api_key" ]]; then
            http_code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${api_key}" "${endpoint}/v1/models" 2> /dev/null || true)
        fi
        http_code="${http_code:-000}"
        if [[ "$http_code" == '200' ]]; then
            log_ok "  API:       ${endpoint}"
        else
            log_warn "  API:       not reachable (${http_code})"
        fi
    fi

    artifacts=$(studio_artifacts "$pod_id")
    if [[ -n "$artifacts" ]]; then
        echo "  Artifacts:"
        printf '%s\n' "$artifacts" | head -10 | awk -F '\t' '{printf "    %.1f MiB  %s\n", $2 / 1048576, $3}'
    else
        echo "  Artifacts: none yet"
    fi
}

cmd_studio_deploy() {
    local config_id=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)
                [[ $# -ge 2 ]] || {
                    log_error "--id requires a value."
                    return 1
                }
                config_id="$2"
                shift 2
                ;;
            *)
                log_error "Unknown Studio deploy argument: $1"
                return 1
                ;;
        esac
    done
    if [[ -n "$config_id" ]]; then
        config_id=$(studio_normalize_id "$config_id") || return 1
    fi
    local pod pod_id pod_name artifacts artifact_path
    pod=$(studio_select_pod "$config_id") || return 1
    [[ -n "$pod" ]] || {
        log_error "No matching Studio pod found."
        return 1
    }
    pod_id=$(printf '%s' "$pod" | jq -r '.id')
    pod_name=$(printf '%s' "$pod" | jq -r '.name')
    config_id=$(studio_config_id "$pod_name")
    artifacts=$(studio_artifacts "$pod_id")

    while IFS=$'\t' read -r _ _ path; do
        [[ -n "$path" ]] || continue
        if [[ "${path,,}" == *.gguf ]]; then
            artifact_path="$path"
            break
        fi
    done <<< "$artifacts"

    [[ -n "$artifact_path" ]] || {
        log_error "No GGUF artifact found. Export one in Unsloth Studio first."
        return 1
    }
    if [[ "$artifact_path" =~ ^(.*)-[0-9]{5}-of-([0-9]{5})\.([gG][gG][uU][fF])$ ]]; then
        local first_shard_path
        first_shard_path="${BASH_REMATCH[1]}-00001-of-${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
        if ! printf '%s\n' "$artifacts" | awk -F '\t' -v path="$first_shard_path" '$3 == path { found = 1 } END { exit !found }'; then
            log_error "The newest split GGUF export is incomplete: ${first_shard_path} is missing."
            return 1
        fi
        artifact_path="$first_shard_path"
    fi

    local state_file config_file configs config deployment_type api_key context_length model_id models_json install_script
    state_file=$(studio_state_file "$config_id")
    config_file="${PROJECT_DIR}/studio.yaml"
    if [[ -f "$state_file" ]]; then
        config_file=$(jq -r --arg fallback "$config_file" '.config_file // $fallback' "$state_file")
    fi
    configs=$(studio_read_configs "$config_file") || return 1
    config=$(printf '%s' "$configs" | jq -c --arg id "$config_id" 'first(.[] | select(.id == $id)) // empty')
    [[ -n "$config" ]] || {
        log_error "Studio config ID not found: ${config_id}"
        return 1
    }
    deployment_type=$(printf '%s' "$config" | jq -r '.type')
    api_key=$(printf '%s' "$config" | jq -r '.api_key')
    context_length=$(printf '%s' "$config" | jq -r '.context_length')

    model_id=$(basename "$artifact_path")
    model_id="${model_id%.*}"
    if [[ "$model_id" =~ ^(.*)-00001-of-[0-9]{5}$ ]]; then
        model_id="${BASH_REMATCH[1]}"
    fi
    model_id=$(printf '%s' "$model_id" | tr ' ' '-')
    models_json=$(jq -n --arg id "$model_id" --arg url "file://${artifact_path}" --argjson context "$context_length" \
        '[{id: $id, url: $url, context_length: $context, parallel: 1, port: 1235}]')

    log_info "Switching ${pod_name} from Studio to llama.cpp..."
    install_script=$(build_install_script_llamacpp)
    run_remote "$pod_id" "$install_script" || return 1
    studio_stop_tunnel "$config_id"
    run_remote "$pod_id" 'STUDIO_ENV=/root/.config/runpod-unsloth-studio.env; [[ -f "${STUDIO_ENV}" ]] || STUDIO_ENV=/workspace/unsloth/runpod-unsloth-studio.env; if [[ -f "${STUDIO_ENV}" ]]; then source "${STUDIO_ENV}"; "${UNSLOTH_BIN}" studio stop >/dev/null 2>&1 || true; fi; pkill -f "[u]nsloth studio" >/dev/null 2>&1 || true; for _ in $(seq 1 30); do pgrep -f "[u]nsloth studio" >/dev/null 2>&1 || break; sleep 1; done; pkill -9 -f "[u]nsloth studio" >/dev/null 2>&1 || true' 'no' || true
    if ! load_configured_deployments_llamacpp "$pod_id" "$pod_name" "$models_json" '' "$api_key"; then
        log_warn "GGUF deployment failed. Restoring Unsloth Studio..."
        studio_activate_studio "$pod_id" "$config_id" || log_error "Unsloth Studio could not be restored automatically."
        return 1
    fi

    mkdir -p "$(dirname "$state_file")"
    if [[ -f "$state_file" ]]; then
        local state_tmp="${state_file}.tmp"
        jq --arg type "$deployment_type" --arg api_key "$api_key" --arg artifact "$artifact_path" --arg model_id "$model_id" --argjson context "$context_length" \
            '.mode = "deploy" | .type = $type | .api_key = $api_key | .artifact = $artifact | .model_id = $model_id | .context_length = $context | .deployed_at = (now | todate)' \
            "$state_file" > "$state_tmp" && mv "$state_tmp" "$state_file" || {
            rm -f "$state_tmp"
            log_error "Could not update Studio state file ${state_file}."
            return 1
        }
        studio_secure_state_file "$state_file"
    else
        umask 077
        jq -n --arg id "$config_id" --arg pod_id "$pod_id" --arg pod_name "$pod_name" --arg type "$deployment_type" --arg api_key "$api_key" \
            --arg config_file "$config_file" \
            --arg artifact "$artifact_path" --arg model_id "$model_id" --argjson context "$context_length" \
            '{id: $id, pod_id: $pod_id, pod_name: $pod_name, type: $type, api_key: $api_key, config_file: $config_file, artifact: $artifact, model_id: $model_id, context_length: $context, mode: "deploy", deployed_at: (now | todate)}' \
            > "$state_file"
        studio_secure_state_file "$state_file"
    fi

    local endpoint
    endpoint=$(pod_lmstudio_url "$pod_id" 60) || {
        log_error "The llama.cpp endpoint did not become available."
        return 1
    }
    log_ok "GGUF deployment is ready: ${endpoint}"
    echo "  Model:     ${model_id}"
    echo "  Artifact:  ${artifact_path}"
    echo "  API key:   ${api_key}"

    local logs_dir run_log call_log gpu
    logs_dir="${PROJECT_DIR}/logs/studio/deploy-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$logs_dir"
    run_log="${logs_dir}/quality.run.log"
    call_log="${logs_dir}/quality.call.log"
    gpu=$(printf '%s' "$pod" | jq -r '.machine.gpuDisplayName // "unknown"')
    log_info "Running one quality test..."
    php "${PACKAGE_DIR}/runpod.php" \
        1 \
        "--pod-url=${endpoint}" \
        "--model-id=${model_id}" \
        "--gpu-name=${gpu}" \
        "--pod-api-key=${api_key}" \
        "--run-log=${run_log}" \
        "--call-log=${call_log}" \
        "--project-dir=${PROJECT_DIR}"
    log_ok "Quality test finished. Logs: ${logs_dir}"
}

cmd_studio_down() {
    local config_id=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id)
                [[ $# -ge 2 ]] || {
                    log_error "--id requires a value."
                    return 1
                }
                config_id="$2"
                shift 2
                ;;
            *)
                log_error "Unknown Studio down argument: $1"
                return 1
                ;;
        esac
    done
    if [[ -n "$config_id" ]]; then
        config_id=$(studio_normalize_id "$config_id") || return 1
    fi

    local pod
    pod=$(studio_select_pod "$config_id") || return 1

    local pod_id='' pod_name='' state_file config_file configs legacy_network_volume_id='' pod_details
    if [[ -n "$pod" ]]; then
        pod_id=$(printf '%s' "$pod" | jq -r '.id')
        pod_name=$(printf '%s' "$pod" | jq -r '.name')
        config_id=$(studio_config_id "$pod_name")
    fi

    config_file="${PROJECT_DIR}/studio.yaml"
    if [[ -z "$config_id" && -f "$config_file" ]]; then
        configs=$(studio_read_configs "$config_file") || return 1
        if [[ "$(printf '%s' "$configs" | jq 'length')" -ne 1 ]]; then
            log_error "Multiple Studio configurations found. Use --id <id>."
            return 1
        fi
        config_id=$(printf '%s' "$configs" | jq -r '.[0].id')
    fi
    [[ -n "$config_id" ]] || {
        log_error "No Studio pod or unambiguous Studio configuration found. Use --id <id>."
        return 1
    }

    state_file=$(studio_state_file "$config_id")
    if [[ -f "$state_file" ]]; then
        legacy_network_volume_id=$(jq -r '.volume_id // empty' "$state_file")
    fi
    if [[ -n "$pod_id" && -z "$legacy_network_volume_id" ]]; then
        pod_details=$(runpod_rest_api GET "/pods/${pod_id}") || return 1
        legacy_network_volume_id=$(printf '%s' "$pod_details" | jq -r '.networkVolumeId // .networkVolume.id // empty')
    fi

    studio_stop_tunnel "$config_id"
    if [[ -n "$pod_id" ]]; then
        log_info "Terminating Studio pod ${pod_name}..."
        runpod_rest_api DELETE "/pods/${pod_id}" > /dev/null || return 1
        log_ok "Studio pod terminated."
    fi

    if [[ -n "$legacy_network_volume_id" ]]; then
        local volumes volume_match volume_deleted=0 attempt
        volumes=$(runpod_rest_api GET '/networkvolumes') || return 1
        volume_match=$(printf '%s' "$volumes" | jq -c --arg id "$legacy_network_volume_id" '
            (if type == "array" then . else (.data // []) end)
            | first(.[] | select(.id == $id)) // empty
        ')
        if [[ -z "$volume_match" ]]; then
            log_warn "Legacy network volume ${legacy_network_volume_id} is already absent."
        fi
        if [[ -n "$volume_match" ]]; then
            log_info "Deleting legacy network volume ${legacy_network_volume_id} and all stored Studio data..."
            for ((attempt = 1; attempt <= 12; attempt++)); do
                if runpod_rest_api DELETE "/networkvolumes/${legacy_network_volume_id}" > /dev/null; then
                    volume_deleted=1
                    break
                fi
                [[ "$attempt" -lt 12 ]] && sleep 5
            done
            if [[ "$volume_deleted" -ne 1 ]]; then
                volumes=$(runpod_rest_api GET '/networkvolumes') || return 1
                volume_match=$(printf '%s' "$volumes" | jq -c --arg id "$legacy_network_volume_id" '
                    (if type == "array" then . else (.data // []) end)
                    | first(.[] | select(.id == $id)) // empty
                ')
                if [[ -n "$volume_match" ]]; then
                    log_error "Studio pod was terminated, but legacy network volume ${legacy_network_volume_id} could not be deleted. Run studio down again."
                    return 1
                fi
            fi
            log_ok "Legacy network volume deleted."
        fi
    fi

    rm -f "$state_file"
    log_ok "Studio pod and all Studio volume data are gone. No RunPod GPU or volume charges remain."
}

cmd_studio() {
    local action="${1:-}"
    case "$action" in
        up) cmd_studio_up "${@:2}" ;;
        status) cmd_studio_status "${@:2}" ;;
        deploy) cmd_studio_deploy "${@:2}" ;;
        down) cmd_studio_down "${@:2}" ;;
        *)
            echo "Usage: $0 studio {up|status|deploy|down}"
            echo "  studio up [--config studio.yaml] [--id <id>] [--dry-run]"
            echo "  studio status [--id <id>]"
            echo "  studio deploy [--id <id>]"
            echo "  studio down [--id <id>]  Permanently delete the pod and all Studio data."
            return 1
            ;;
    esac
}
