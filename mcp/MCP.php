<?php

use PhpMcp\Server\Attributes\McpTool;

class MCP
{
    /**
     * Create a new RunPod pod, install LM Studio, download the model and start the server.
     *
     * @param string $id              Short config ID for this pod, e.g. "001".
     * @param string $gpu             GPU type, e.g. "NVIDIA A40" or "NVIDIA GeForce RTX 5090".
     * @param int    $hdd             Container disk size in GB, e.g. 50.
     * @param string $model           HuggingFace model ID, e.g. "unsloth/Qwen3.5-27B-GGUF-UD-Q4_K_XL".
     * @param int    $contextLength   Context window size in tokens, e.g. 32768.
     * @param int|null $autoDestroyOnIdle Terminate pod after this many seconds of idle. Optional.
     *
     * @return string Shell output of the create command.
     */
    #[McpTool(name: 'runpod_create')]
    public function create(
        string $id,
        string $gpu,
        int $hdd,
        string $model,
        int $contextLength,
        ?int $autoDestroyOnIdle = null
    ): string {
        $script = dirname(__DIR__) . '/runpod.sh';
        $args = [
            escapeshellarg($script),
            'create',
            '--id',
            escapeshellarg($id),
            '--gpu',
            escapeshellarg($gpu),
            '--hdd',
            (int) $hdd,
            '--model',
            escapeshellarg($model),
            '--context-length',
            (int) $contextLength
        ];
        if ($autoDestroyOnIdle !== null) {
            $args[] = '--auto-destroy-on-idle';
            $args[] = (int) $autoDestroyOnIdle;
        }
        return $this->run('bash ' . implode(' ', $args));
    }

    /**
     * Terminate all running RunPod pods and clean up Cloudflare DNS and redirect entries.
     *
     * @return string Shell output of the delete command.
     */
    #[McpTool(name: 'runpod_delete')]
    public function delete(): string
    {
        return $this->run('bash ' . escapeshellarg(dirname(__DIR__) . '/runpod.sh') . ' delete');
    }

    /**
     * Show the current status of all running RunPod pods, including LM Studio and model state.
     *
     * @return string Shell output of the status command.
     */
    #[McpTool(name: 'runpod_status')]
    public function status(): string
    {
        return $this->run('bash ' . escapeshellarg(dirname(__DIR__) . '/runpod.sh') . ' status');
    }

    /**
     * Run inference tests against all RUNNING pods in parallel.
     *
     * @param int $runs Number of test runs per pod. Defaults to 1.
     *
     * @return string Shell output of the test command.
     */
    #[McpTool(name: 'runpod_test')]
    public function test(int $runs = 1): string
    {
        return $this->run('bash ' . escapeshellarg(dirname(__DIR__) . '/runpod.sh') . ' test --runs ' . (int) $runs);
    }

    /**
     * Run a shell command, capture stdout and stderr combined, strip ANSI escape codes.
     *
     * @param string $command The shell command to execute.
     *
     * @return string Combined output with ANSI codes removed.
     */
    private function run(string $command): string
    {
        $output = shell_exec($command . ' 2>&1') ?? '';
        return preg_replace('/\x1b\[[0-9;]*[mGKHF]/', '', $output);
    }
}
