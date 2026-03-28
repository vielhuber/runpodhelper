# ⛈ runpodhelper ⛈

runpodhelper automates the full lifecycle of self-hosted llm inference on runpod gpu cloud. it provisions pods via the runpod graphql api, installs lm studio, downloads gguf models from huggingface, and serves them behind a cloudflare tunnel.

## usage

```sh
./vendor/bin/runpod.sh create \
    --gpu "RTX 5090" \
    --hdd 50 \
    --model "unsloth/Qwen3.5-27B-GGUF-UD-Q4_K_XL" \
    --lmstudio-api-key "your-static-api-key" \
    --auto-destroy 3600 \
    --context-length 131072 \
    --parallel 2
```

- `./vendor/bin/runpod.sh status`
- `./vendor/bin/runpod.sh delete --all`
- `./vendor/bin/runpod.sh delete --id 001`
- `./vendor/bin/runpod.sh test quality --runs 5`
- `./vendor/bin/runpod.sh test quantity --runs 80`

```sh
./vendor/bin/runpod.sh scale --start \
    --gpu "RTX 5090" \
    --hdd 50 \
    --model "unsloth/Qwen3.5-27B-GGUF-UD-Q4_K_XL" \
    --lmstudio-api-key "your-static-api-key" \
    --auto-destroy 3600 \
    --context-length 131072 \
    --parallel 2 \
    --pod-count 20

./vendor/bin/runpod.sh scale --stop
./vendor/bin/runpod.sh scale --pod-count 20
./vendor/bin/runpod.sh scale --refresh --context-length 65536 --parallel 2
./vendor/bin/runpod.sh scale --refresh
```

- `parallel * context-length = token-budget-per-gpu`
- `max-workers = parallel * pods`
- RTX 5090 (32 GB VRAM) fits ~128k token budget → `--context-length 65536 --parallel 2`
- rule of thumb: `pod-count ≈ 0.2 × parallel-agentic-tasks` (e.g. 40 tasks → 8 pods)

## installation

- install library
    - `composer require vielhuber/runpodhelper`
    - `./vendor/bin/runpod.sh init`
- setup cloudflare
    - Create a domain `custom.xyz`
    - Profile > API Tokens > Create Token
        - Permissions:
            - `Zone / DNS / Edit`
            - `Zone / Single Redirect / Edit`
            - `Account / Cloudflare Tunnel / Edit`
        - Account Resources
            - `Include > Your account`
        - Zone Resource
            - Include / Specific zone / `custom.xyz`
    - Set `CLOUDFLARE_DOMAIN`/`CLOUDFLARE_API_KEY` in `.env`
    - Each pod gets a subdomain based on its config ID:
        - `001.custom.xyz`
        - `002.custom.xyz`
        - …
- edit config
    - `vi ./.env`
    - `vi ./models.yaml`

## mcp server

```json
{
    "mcpServers": {
        "runpodhelper": {
            "command": "/usr/bin/php",
            "args": ["/path/to/project/runpodhelper/bin/mcp-server.php"]
        }
    }
}
```

## recommended models

| Name                    | HDD   | Model                        | Context length | Parallel | tok/s | Notes                                       |
| ----------------------- | ----- | ---------------------------- | -------------- | -------- | ----- | ------------------------------------------- |
| NVIDIA GeForce RTX 5090 | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL | 65536          | 2        | ~43   | best current MCP/tool-use baseline          |
| NVIDIA A40              | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL | 65536          | 2        | ~20   | discontinued/unavailable as of 2026-03      |

## manual deployment

- [https://www.runpod.io](https://www.runpod.io) > Pods > Deploy
- Pod template > Edit
- Expose HTTP ports (comma separated): `1234`
- Container Disk: `100 GB`
- Copy: SSH over exposed TCP
- `ssh root@xxxxxxxxxx -p xxxxx`

```sh
curl -fsSL https://lmstudio.ai/install.sh | bash
export PATH="/root/.lmstudio/bin:$PATH"
# this is unreliable
#lms get -y qwen/qwen3-coder-next
mkdir -p ~/.lmstudio/models/unsloth/MiniMax-M2.1-GGUF
cd ~/.lmstudio/models/unsloth/MiniMax-M2.1-GGUF
wget -c https://huggingface.co/unsloth/MiniMax-M2.1-GGUF/resolve/main/MiniMax-M2.1-UD-TQ1_0.gguf
mkdir -p ~/.lmstudio/models/lmstudio-community/Qwen3.5-35B-A3B-GGUF
cd ~/.lmstudio/models/lmstudio-community/Qwen3.5-35B-A3B-GGUF
wget -c https://huggingface.co/lmstudio-community/Qwen3.5-35B-A3B-GGUF/resolve/main/Qwen3.5-35B-A3B-Q4_K_M.gguf
lms server start --port 1234 --bind 0.0.0.0
```

## alternative: use runpodctl

- `ssh-keygen -t ed25519 -C "name@tld.com"`
- `wget https://github.com/Run-Pod/runpodctl/releases/download/v1.14.3/runpodctl-linux-amd64 -O runpodctl`
- `chmod +x runpodctl`
- `mv runpodctl /usr/bin/runpodctl`
- `runpodctl config --apiKey <RUNPOD_API_KEY>`
- `runpodctl version`

## more commands

- `curl http://localhost:1234/v1/models`
- `lms --help`
- `lms status`
- `lms server stop`
- Copy: HTTP services > URL

```sh
curl https://xxxxxxxxx-1234.proxy.runpod.net/v1/responses \
  -X POST \
  -H "Content-Type: application/json" \
    -H "Authorization: Bearer your-static-api-key" \
  -d '{
    "model": "xxxxxxxxxxxxx",
    "messages": [
        {"role": "user", "content": [{"type": "input_text", "text": "hi"}]}
    ],
    "temperature": 1.0,
    "stream": true
  }'
```
