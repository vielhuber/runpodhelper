[![GitHub Tag](https://img.shields.io/github/v/tag/vielhuber/runpodhelper)](https://github.com/vielhuber/runpodhelper/tags)
[![Code Style](https://img.shields.io/badge/code_style-psr--12-ff69b4.svg)](https://www.php-fig.org/psr/psr-12/)
[![License](https://img.shields.io/github/license/vielhuber/runpodhelper)](https://github.com/vielhuber/runpodhelper/blob/main/LICENSE.md)
[![Last Commit](https://img.shields.io/github/last-commit/vielhuber/runpodhelper)](https://github.com/vielhuber/runpodhelper/commits)
[![PHP Version Support](https://img.shields.io/packagist/php-v/vielhuber/runpodhelper)](https://packagist.org/packages/vielhuber/runpodhelper)
[![Packagist Downloads](https://img.shields.io/packagist/dt/vielhuber/runpodhelper)](https://packagist.org/packages/vielhuber/runpodhelper)

# ⛈ runpodhelper ⛈

runpodhelper automates the full lifecycle of self-hosted llm inference on runpod gpu cloud. it provisions pods via the runpod graphql api, installs lm studio or llama.cpp, downloads gguf models from huggingface, and serves them behind a cloudflare tunnel.

## usage

```sh
./vendor/bin/runpod.sh create \
    --gpu "RTX 5090" \
    --hdd 50 \
    --model "unsloth/Qwen3.5-27B-GGUF-UD-Q4_K_XL" \
    --image "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404" \
    --type "lmstudio" \
    --api-key "your-static-api-key" \
    --context-length 65536 \
    --parallel 2 \
    --datacenter "EUR-IS-2" \
    --auto-destroy 3600
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
    --image "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404" \
    --type "lmstudio" \
    --api-key "your-static-api-key" \
    --context-length 65536 \
    --parallel 2 \
    --datacenter "EUR-IS-2" \
    --auto-destroy 3600 \
    --pod-count 3

./vendor/bin/runpod.sh scale --start \
    --gpu "L40S" \
    --hdd 60 \
    --model "unsloth/Qwen3.5-35B-A3B-GGUF" \
    --image "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404" \
    --type "llamacpp" \
    --api-key "your-static-api-key" \
    --context-length 131072 \
    --parallel 1 \
    --pod-count 1

./vendor/bin/runpod.sh scale --start \
    --gpu "2x RTX PRO 6000" \
    --hdd 250 \
    --model "unsloth/MiniMax-M2.7-GGUF-UD-Q4_K_XL" \
    --image "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404" \
    --type "llamacpp" \
    --api-key "your-static-api-key" \
    --context-length 131072 \
    --parallel 1 \
    --pod-count 1

./vendor/bin/runpod.sh scale --stop
./vendor/bin/runpod.sh scale --pod-count 20
./vendor/bin/runpod.sh scale --refresh --context-length 65536 --parallel 2
./vendor/bin/runpod.sh scale --refresh
```

## rules

- `gpu-vram ≈ model-size + context-length * model-factor`
- `token-budget-per-session ≈ parallel * context-length`
- `workers-per-pod ≈ workers-count / pod-count`
- `running-workers-per-pod ≈ parallel`
- `concurrent-workers ≈ parallel * pod-count`
- `concurrent-workers ≈ 0.2 * parallel * workers-count`
- `pod-count ≈ 0.2 * workers-count`

### RTX 5090 + Qwen3.5-27B

- `gpu-vram ≈ 32 GB`
- `model-size ≈ 17.6 GB`
- `model-factor ≈ 0.00022`
- `=> max-context-length ≈ 65536`
- `=> max-parallel ≈ 2` (at context-length 65536)

### L40S + Qwen3.5-27B

- `gpu-vram ≈ 48 GB`
- `model-size ≈ 17.6 GB`
- `model-factor ≈ 0.00022`
- `=> max-context-length ≈ 138240`
- `=> max-parallel ≈ 4` (at context-length 65536)

### RTX PRO 6000 + Qwen3.5-122B-A10B (MoE)

- `gpu-vram ≈ 96 GB`
- `model-size ≈ 66 GB`
- `model-factor ≈ 0.00013` (MoE, 10B active params)
- `=> max-context-length ≈ 131072` (128K model limit)
- `=> max-parallel ≈ 1` (at context-length 131072, ~83 GB total)
- `=> max-parallel ≈ 2` (at context-length 98304, ~92 GB total)

### RTX PRO 6000 + Qwen3.5-27B

- `gpu-vram ≈ 96 GB`
- `model-size ≈ 17.6 GB`
- `model-factor ≈ 0.00022`
- `=> max-context-length ≈ 356352`
- `=> max-parallel ≈ 10` (at context-length 65536)

### RTX PRO 6000 + gemma-4-26B-A4B (MoE)

- `gpu-vram ≈ 96 GB`
- `model-size ≈ 27.9 GB`
- `model-factor ≈ 0.00013` (MoE, 30 layers)
- `=> max-context-length ≈ 256K (model limit)`
- `=> max-parallel ≈ 8` (at context-length 65536)

### RTX PRO 6000 + gemma-4-31B

- `gpu-vram ≈ 96 GB`
- `model-size ≈ 27.5 GB`
- `model-factor ≈ 0.00025` (dense, 60 layers)
- `=> max-context-length ≈ 256K (model limit)`
- `=> max-parallel ≈ 4` (at context-length 65536)

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

| Name                    | HDD   | Model                              | Context length | Parallel | tok/s | Notes                                              |
| ----------------------- | ----- | ---------------------------------- | -------------- | -------- | ----- | -------------------------------------------------- |
| NVIDIA GeForce RTX 5090 | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL        | 65536          | 2        | ~43   | best current MCP/tool-use baseline                 |
| NVIDIA L40S             | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL        | 65536          | 4        | ~25   | 2x parallel slots vs. RTX 5090                     |
| NVIDIA RTX PRO 6000     | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL        | 65536          | 10       | ~20   | max parallel slots, single pod                     |
| NVIDIA RTX PRO 6000     | 50 GB | gemma-4-26B-A4B-it-GGUF-UD-Q8_K_XL | 65536          | 8        | ~65   | MoE: 3.8B active params, best parallelism on 96 GB |
| NVIDIA RTX PRO 6000     | 50 GB | gemma-4-31B-it-GGUF-UD-Q6_K_XL     | 65536          | 4        | ~18   | dense, best reliability on 96 GB                   |
| NVIDIA RTX PRO 6000     | 80 GB | Qwen3.5-122B-A10B-GGUF-UD-Q4_K_XL  | 131072         | 1        | ~?    | MoE: 10B active params, #1 intelligence index      |
| NVIDIA A40              | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL        | 65536          | 2        | ~20   | discontinued/unavailable as of 2026-03             |

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
