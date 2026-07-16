<?php
declare(strict_types=1);
namespace vielhuber\runpodhelper;

use PhpMcp\Server\Attributes\McpTool;

final class MCP
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
            '--api-key',
            escapeshellarg($lmstudioApiKey)
        ];
        if ($autoDestroy !== null) {
            $args[] = '--auto-destroy';
            $args[] = (int) $autoDestroy;
        }
        $logFile = $this->findProjectDir() . '/logs/mcp-create-' . $id . '-' . date('Ymd-His') . '.log';
        if (!is_dir(dirname($logFile))) {
            mkdir(dirname($logFile), 0755, true);
        }
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
     * Create or reuse a persistent volume, start Unsloth Studio and expose it through a local SSH tunnel.
     *
     * @param string $config Path to the Studio YAML configuration in the project directory.
     * @param string|null $id Optional Studio config ID when multiple entries exist.
     *
     * @return string Confirmation with the background log path.
     */
    #[McpTool(name: 'runpod_studio_up')]
    public function studioUp(string $config = 'studio.yaml', ?string $id = null): string
    {
        $script = escapeshellarg(dirname(__DIR__) . '/runpod.sh');
        $command = 'bash ' . $script . ' studio up --config ' . escapeshellarg($config);
        if ($id !== null) {
            $command .= ' --id ' . escapeshellarg($id);
        }
        $logFile = $this->findProjectDir() . '/logs/mcp-studio-up-' . date('Ymd-His') . '.log';
        if (!is_dir(dirname($logFile))) {
            mkdir(dirname($logFile), 0755, true);
        }
        return $this->runAsync($command, $logFile);
    }

    /**
     * Show Studio, GPU, persistent volume and exported artifact status.
     *
     * @param string|null $id Optional Studio config ID when multiple Studio pods exist.
     *
     * @return string Shell output of the Studio status command.
     */
    #[McpTool(name: 'runpod_studio_status')]
    public function studioStatus(?string $id = null): string
    {
        $command = 'bash ' . escapeshellarg(dirname(__DIR__) . '/runpod.sh') . ' studio status';
        if ($id !== null) {
            $command .= ' --id ' . escapeshellarg($id);
        }
        return $this->run($command);
    }

    /**
     * Deploy the latest Studio GGUF with llama.cpp and run one quality test.
     *
     * @param string|null $id Optional Studio config ID.
     *
     * @return string Confirmation with the background log path.
     */
    #[McpTool(name: 'runpod_studio_deploy')]
    public function studioDeploy(?string $id = null): string
    {
        $script = escapeshellarg(dirname(__DIR__) . '/runpod.sh');
        $command = 'bash ' . $script . ' studio deploy';
        if ($id !== null) {
            $command .= ' --id ' . escapeshellarg($id);
        }
        $logFile = $this->findProjectDir() . '/logs/mcp-studio-deploy-' . date('Ymd-His') . '.log';
        if (!is_dir(dirname($logFile))) {
            mkdir(dirname($logFile), 0755, true);
        }
        return $this->runAsync($command, $logFile);
    }

    /**
     * Permanently delete the Studio pod and all stored artifacts.
     *
     * @param string|null $id Optional Studio config ID.
     *
     * @return string Shell output of the Studio down command.
     */
    #[McpTool(name: 'runpod_studio_down')]
    public function studioDown(?string $id = null): string
    {
        $command = 'bash ' . escapeshellarg(dirname(__DIR__) . '/runpod.sh') . ' studio down';
        if ($id !== null) {
            $command .= ' --id ' . escapeshellarg($id);
        }
        return $this->run($command);
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
