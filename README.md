# ⛈ runpodhelper ⛈

runpodhelper automates the full lifecycle of self-hosted llm inference on runpod gpu cloud. it provisions pods via the runpod graphql api, installs lm studio, downloads gguf models from huggingface, and serves them behind a cloudflare tunnel — all driven by a single yaml config. a php-based test runner benchmarks deployed models across chat, reasoning, and agentic (mcp) workloads and produces structured summaries with per-model throughput and success rates.

## usage

- `./runpod.sh status`
- `./runpod.sh create`
- `./runpod.sh load`
- `./runpod.sh unload`
- `./runpod.sh delete`

## installation

- `ssh-keygen -t ed25519 -C "name@tld.com"`
- `wget https://github.com/Run-Pod/runpodctl/releases/download/v1.14.3/runpodctl-linux-amd64 -O runpodctl`
- `chmod +x runpodctl`
- `mv runpodctl /usr/bin/runpodctl`
- `runpodctl config --apiKey <RUNPOD_API_KEY>`
- `composer install`
- `cp ./.env.example ./.env`
- `vi ./.env`
- `vi ./runpod.yaml`

## cloudflare setup

- Domains > `Do not block (allow crawlers)` + `Disable robots.txt configuration`
- Security > Settings > Browser integrity check: off
- SSL/TLS > Overview > Configure > Flexible
  Profile > API Tokens > Create Token > Edit zone DNS > Zone Resource > Include / Specific zone / rebuhleiv.xyz

## recommended models

| GPU      | HDD   | Model                       | Context length | tok/s | Notes                                       |
| -------- | ----- | --------------------------- | -------------- | ----- | ------------------------------------------- |
| RTX 5090 | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL | 32768          | ~43   | best current MCP/tool-use baseline          |
| A40      | 50 GB | Qwen3.5-27B-GGUF-UD-Q4_K_XL | 32768          | ~20   | ~2× slower than RTX 5090, identical quality |

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
  -d '{
    "model": "xxxxxxxxxxxxx",
    "messages": [
        {"role": "user", "content": [{"type": "input_text", "text": "hi"}]}
    ],
    "temperature": 1.0,
    "stream": true
  }'
```
