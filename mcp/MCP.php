<?php
namespace vielhuber\runpodhelper;

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
    * @param string $lmstudioApiKey  Static API key used by the nginx reverse proxy in front of LM Studio.
     * @param int|null $autoDestroy Terminate pod after this many seconds. Optional.
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
        string $lmstudioApiKey,
        ?int $autoDestroy = null
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
            (int) $contextLength,
            '--lmstudio-api-key',
            escapeshellarg($lmstudioApiKey)
        ];
        if ($autoDestroy !== null) {
            $args[] = '--auto-destroy';
            $args[] = (int) $autoDestroy;
        }
        $logFile = $this->findProjectDir() . '/logs/mcp-create-' . $id . '-' . date('Ymd-His') . '.log';
        @mkdir(dirname($logFile), 0755, true);
        return $this->runAsync('bash ' . implode(' ', $args), $logFile);
    }

    /**
     * Terminate RunPod pod(s) and clean up Cloudflare DNS and redirect entries.
     *
     * Pass either $all = true to terminate every pod, or $id to target a single pod by its config ID (e.g. "001").
     *
     * @param bool        $all Terminate all pods when true.
     * @param string|null $id  Config ID of a single pod to terminate, e.g. "001".
     *
     * @return string Shell output of the delete command.
     */
    #[McpTool(name: 'runpod_delete')]
    public function delete(bool $all = false, ?string $id = null): string
    {
        $script = escapeshellarg(dirname(__DIR__) . '/runpod.sh');
        if ($all) {
            return $this->run('bash ' . $script . ' delete --all');
        }
        if ($id !== null) {
            return $this->run('bash ' . $script . ' delete --id ' . escapeshellarg($id));
        }
        return 'Error: either $all must be true or $id must be provided.';
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
     * Run a shell command in the background (fire-and-forget).
     * Output is written to $logFile. Returns immediately.
     *
     * @param string $command The shell command to execute.
     * @param string $logFile Absolute path to the log file.
     *
     * @return string Confirmation message with log path.
     */
    private function runAsync(string $command, string $logFile): string
    {
        $projectDir = $this->findProjectDir();
        $fullCommand =
            'cd ' .
            escapeshellarg($projectDir) .
            ' && nohup ' .
            $command .
            ' > ' .
            escapeshellarg($logFile) .
            ' 2>&1 &';
        exec($fullCommand);
        return 'Started in background. Log: ' . $logFile;
    }

    /**
     * Run a shell command inside the consuming project's root directory.
     * Determines the project root by walking up from the package directory
     * until a .env file is found. Captures stdout+stderr and strips ANSI codes.
     *
     * @param string $command The shell command to execute.
     *
     * @return string Combined output with ANSI codes removed.
     */
    private function run(string $command): string
    {
        $projectDir = $this->findProjectDir();
        $fullCommand = 'cd ' . escapeshellarg($projectDir) . ' && ' . $command . ' 2>&1';
        $output = shell_exec($fullCommand) ?? '';
        return preg_replace('/\x1b\[[0-9;]*[mGKHF]/', '', $output);
    }

    /**
     * Walk up from the package directory until a .env file is found.
     * Falls back to the package directory itself.
     *
     * @return string Absolute path to the project root.
     */
    private function findProjectDir(): string
    {
        $dir = dirname(__DIR__);
        while ($dir !== dirname($dir)) {
            if (file_exists($dir . '/.env')) {
                return $dir;
            }
            $dir = dirname($dir);
        }
        return dirname(__DIR__);
    }
}
