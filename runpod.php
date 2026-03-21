<?php
$autoloader = __DIR__ . '/vendor/autoload.php';
if (!file_exists($autoloader)) {
    $dir = __DIR__;
    while ($dir !== dirname($dir)) {
        $dir = dirname($dir);
        $candidate = $dir . '/vendor/autoload.php';
        if (file_exists($candidate)) {
            $autoloader = $candidate;
            break;
        }
    }
}
require_once $autoloader;

use vielhuber\aihelper\aihelper;

final class RunpodTestRunner
{
    private array $arguments = [];
    private int $run_count = 1;
    private ?string $selected_pod_url = null;
    private ?string $selected_model_id = null;
    private ?string $selected_gpu_name = null;
    private ?string $selected_pod_api_key = null;
    private ?string $mode = null;
    private string $run_log_file;
    private string $call_log_file;
    private array $pods = [];
    private array $mcp = [];
    private array $summary = [];
    private int $total_requests = 0;
    private int $total_successful_requests = 0;
    private float $total_time = 0.0;

    public function init(): void
    {
        $this->arguments = $_SERVER['argv'] ?? [];

        $projectDir = $this->getCliOption('project-dir') ?? __DIR__;
        $dotenv = \Dotenv\Dotenv::createImmutable($projectDir);
        $dotenv->load();

        $this->run_count = max(1, (int) ($this->arguments[1] ?? 1));
        $this->selected_pod_url = $this->getCliOption('pod-url');
        $this->selected_model_id = $this->getCliOption('model-id');
        $this->selected_gpu_name = $this->getCliOption('gpu-name');
        $this->selected_pod_api_key =
            $this->getCliOption('pod-api-key') ??
            ($_SERVER['RUNPOD_LMSTUDIO_API_KEY'] ?? null) ??
            ($_SERVER['LMSTUDIO_API_KEY'] ?? null);
        $this->mode = $this->getCliOption('mode');
        $this->run_log_file = $this->getCliOption('run-log') ?? __DIR__ . '/runpod_run.log';
        $this->call_log_file = $this->getCliOption('call-log') ?? __DIR__ . '/runpod_call.log';

        $this->initializeLogs();
        $this->loadPods();
        $this->loadMcpServers();

        if ($this->mode === 'parallel-browser') {
            $this->runParallelBrowserTest();

            return;
        }

        $this->runAllTests();
        $this->printSummary();
    }

    private function getCliOption(string $name): ?string
    {
        foreach ($this->arguments as $argument) {
            $prefix = '--' . $name . '=';
            if (str_starts_with($argument, $prefix)) {
                return substr($argument, strlen($prefix));
            }
        }

        return null;
    }

    private function initializeLogs(): void
    {
        file_put_contents($this->run_log_file, '');
        file_put_contents($this->call_log_file, '');
        ob_implicit_flush(true);
        ob_start(function ($buffer) {
            file_put_contents($this->run_log_file, $buffer, FILE_APPEND);
            return $buffer;
        }, 1);
    }

    private function loadPods(): void
    {
        echo 'ℹ️ Dynamically extracting pods...' . PHP_EOL;

        if (($this->selected_pod_url ?? '') !== '' && ($this->selected_model_id ?? '') !== '') {
            $this->pods[] = [
                'url' => $this->selected_pod_url,
                'model_id' => $this->selected_model_id,
                'gpu_name' => $this->selected_gpu_name,
                'api_key' => $this->selected_pod_api_key
            ];
        } else {
            $status = shell_exec('bash ' . __DIR__ . '/runpod.sh status 2>/dev/null') ?? '';
            $status = preg_replace('/\x1b\[[0-9;]*[mGKHF]/', '', $status);
            $blocks = preg_split('/^=== .+ ===$/m', $status);
            foreach ($blocks as $block) {
                preg_match('#https://[a-z0-9]+-1234\.proxy\.runpod\.net#', $block, $url);
                preg_match('/Loaded:\s+(\S+)/', $block, $model);
                if (!empty($url[0]) && !empty($model[1]) && $model[1] !== 'none') {
                    $this->pods[] = [
                        'url' => $url[0],
                        'model_id' => $model[1],
                        'gpu_name' => null,
                        'api_key' => $this->selected_pod_api_key
                    ];
                }
            }
        }

        if (empty($this->pods)) {
            echo '⛔ Failed to get pods.' . PHP_EOL;
            die();
        }

        echo '✅ Successfully extracted ' . count($this->pods) . ' pods.' . PHP_EOL;
        echo 'ℹ️ Planned runs: ' . $this->run_count . PHP_EOL;
    }

    private function loadMcpServers(): void
    {
        $auth_token = null;

        if (!empty($_SERVER['MCP_SERVER_TEST_AUTH_URL'] ?? '')) {
            $return = __curl(
                $_SERVER['MCP_SERVER_TEST_AUTH_URL'],
                [
                    'client_id' => $_SERVER['MCP_SERVER_TEST_AUTH_CLIENT_ID'] ?? '',
                    'client_secret' => $_SERVER['MCP_SERVER_TEST_AUTH_CLIENT_SECRET'] ?? '',
                    'audience' => $_SERVER['MCP_SERVER_TEST_AUTH_AUDIENCE'] ?? '',
                    'grant_type' => 'client_credentials'
                ],
                'POST'
            );
            $auth_token = $return->result->access_token ?? null;
            if (empty($auth_token)) {
                echo '⛔ MCP auth failed.' . PHP_EOL;
                die();
            }
        }

        $index = 1;
        while (!empty($_SERVER['MCP_SERVER_TEST_' . $index . '_URL'] ?? '')) {
            $this->mcp[] = [
                'name' => 'MCP Server ' . $index,
                'url' => $_SERVER['MCP_SERVER_TEST_' . $index . '_URL'],
                'authorization_token' => $auth_token
            ];
            $index++;
        }

        echo PHP_EOL;
    }

    private function runAllTests(): void
    {
        for ($run_index = 1; $run_index <= $this->run_count; $run_index++) {
            echo '========================================' . PHP_EOL;
            echo 'ℹ️ Run ' . $run_index . '/' . $this->run_count . PHP_EOL;
            echo '========================================' . PHP_EOL;
            foreach ($this->pods as $pod) {
                $result = $this->runPodTestBatch($pod);
                $this->mergeSummary($result['summary']);
                $this->total_requests += $result['total_requests'];
                $this->total_successful_requests += $result['total_successful_requests'];
                $this->total_time += $result['total_time'];
            }
            echo '----------------------------------------' . PHP_EOL;
            echo '----------------------------------------' . PHP_EOL;
        }
    }

    private function buildMcpUrl(string $url, string $chat_id): string
    {
        return str_replace('CHAT_ID', $chat_id, $url);
    }

    private function getPodLogLabel(array $pod): string
    {
        $label = $pod['model_id'];
        if (($pod['gpu_name'] ?? '') !== '') {
            $label .= ' [' . $pod['gpu_name'] . ']';
        }

        return $label;
    }

    private function buildMcpServers(): array
    {
        $chat_id = __random_string(10);
        $mcp_servers = [];

        foreach ($this->mcp as $mcp_server_template) {
            if (!$this->shouldIncludeMcpServer($mcp_server_template)) {
                continue;
            }
            $mcp_server = $mcp_server_template;
            $mcp_server['url'] = $this->buildMcpUrl($mcp_server_template['url'], $chat_id);
            $mcp_servers[] = $mcp_server;
        }

        return $mcp_servers;
    }

    private function buildBrowserMcpServers(): array
    {
        $chat_id = __random_string(10);
        $mcp_servers = [];

        foreach ($this->mcp as $mcp_server_template) {
            if (!str_contains($mcp_server_template['url'] ?? '', '/api/browser')) {
                continue;
            }
            $mcp_server = $mcp_server_template;
            $mcp_server['url'] = $this->buildMcpUrl($mcp_server_template['url'], $chat_id);
            $mcp_servers[] = $mcp_server;
        }

        return $mcp_servers;
    }

    private function shouldIncludeMcpServer(array $mcp_server_template): bool
    {
        $url = $mcp_server_template['url'] ?? '';

        return str_contains($url, '/api/filesystem/mcp/') ||
            str_contains($url, '/api/browser') ||
            str_contains($url, '/api/word/mcp/') ||
            str_contains($url, '/api/email/mcp/');
    }

    private function buildPrompts(array $pod): array
    {
        $random_value = __random_string(10);
        $document_filename = 'datei_endungen_' . __random_string(8) . '.docx';
        $document_path = '/tmp/' . $document_filename;

        return [
            [
                'Hallo! Wie geht es Dir?',
                false,
                function ($response) {
                    return strlen($response) > 10;
                },
                60
            ],
            [
                'Was ist 17*43?',
                false,
                function ($response) {
                    return strpos($response, '731') !== false;
                },
                60
            ],
            [
                'Erzähl mir eine Geschichte.',
                false,
                function ($response) {
                    return strlen($response) > 100;
                },
                120
            ],
            [
                '
                Dir stehen MCP-Tools fuer Dateisystem, Browser, Word und E-Mail zur Verfuegung.
                Wenn ein passendes Tool verfuegbar ist, nutze es. Behaupte nicht, dass du etwas nicht kannst, bevor du die vorhandenen Tools verwendet hast.
                Arbeite strikt sequentiell und fuehre immer nur den naechsten noetigen Schritt aus.
                Rufe den jeweils noetigen Tool-Call direkt auf und kuendige ihn nicht erst in Text an.
                Gib vor dem abschliessenden Ergebnis keinen erklaerenden Fliesstext aus, ausser es ist fuer den unmittelbaren naechsten Tool-Call zwingend noetig.
                Speichere temporäre Dateien im Ordner /tmp.
                Nutze den Browser in diesem Test zwingend.
                Öffne mit browser_navigate die Seite https://en.wikipedia.org/wiki/List_of_filename_extensions_(A%E2%80%93E).
                Verwende genau diese 5 konkreten Dateiendungen als Beispiele: .AAC, .ACCDB, .AIFF, .APK, .ARC.
                Erstelle ein kurzes Word-Dokument nur mit diesen 5 Dateiendungen und je einer kurzen Erklärung.
                Verwende fuer das Dokument genau eine Ueberschrift und genau eine Tabelle mit 2 Spalten (Dateiendung, Erklaerung) und 5 Datenzeilen.
                Nutze fuer den Tabelleninhalt nach Moeglichkeit einen einzigen add_table-Call und vermeide mehrere add_paragraph-Calls.
                Gib die 5 ausgewaehlten Dateiendungen nicht vorab als nummerierte Liste oder laengeren Zwischentext aus, sondern uebernimm sie direkt in das Dokument bzw. den add_table-Call.
                Rufe nach browser_navigate moeglichst direkt create_document, add_heading und add_table auf.
                Verwende für das Word-Dokument exakt diesen Pfad: "' .
                $document_path .
                '".
                Verwende keinen anderen Dateipfad als diesen fuer das Word-Dokument.
                Schließe den Browser danach vollständig mit browser_close_browser (nicht browser_close).
                Sende anschließend eine E-Mail von noreply@vielhuber.de an noreply@vielhuber.de.
                Der Betreff der E-Mail muss exakt "' .
                $random_value .
                '" lauten.
                Haenge exakt die Datei "' .
                $document_path .
                '" an.
                Schreibe den Modellnamen "' .
                $pod['model_id'] .
                '" in den Inhalt der E-Mail.
                Prüfe anschließend (wenn nötig bis zu 3x) den Posteingang von noreply@vielhuber.de (LIMIT 10), ob wirklich eine E-Mail mit dem Betreff "' .
                $random_value .
                '" mit Anhang vorhanden ist (Limit 10, um die letzten E-Mails zu holen).
                Schau dann nach dem Betreff "' .
                $random_value .
                '".
                Führe anschließend view_mail (ohne EML oder Anhänge) und prüfe die Dateigröße des Anhangs.
                Dann ist die Aufgabe beendet und du darfst keine weiteren Tools mehr aufrufen.
                Gib erst ganz am Ende das Ergebnis aus.
                Halte Zwischenausgaben knapp und ohne Codeblöcke.
                Deine letzte Ausgabe darf nur genau eines dieser beiden Ergebnisse sein: "ANHANG VORHANDEN" oder "ANHANG NICHT VORHANDEN".
            ',
                true,
                function ($response) {
                    return strlen($response) > 10 && strpos($response, 'ANHANG VORHANDEN') !== false;
                },
                300
            ]
        ];
    }

    private function inferSamplingProfile(string $prompt_text, bool $uses_mcp): string
    {
        if ($uses_mcp) {
            return 'agentic';
        }

        $normalized_prompt_text = mb_strtolower(__remove_newlines($prompt_text));

        if (str_contains($normalized_prompt_text, 'geschichte')) {
            return 'creative';
        }

        if (preg_match('/\d+\s*[\*\+\-x\/]\s*\d+/', $normalized_prompt_text) === 1) {
            return 'reasoning';
        }

        return 'default';
    }

    private function getSamplingConfiguration(string $model_id, string $profile): array
    {
        $normalized_model_id = strtolower($model_id);
        $is_qwq = str_contains($normalized_model_id, 'qwq');
        $is_qwen3_5 = str_contains($normalized_model_id, 'qwen3.5');
        $is_qwen3 = str_contains($normalized_model_id, 'qwen3');
        $is_gpt_oss = str_contains($normalized_model_id, 'gpt-oss');

        if ($is_qwq) {
            return [
                'profile' => 'reasoning',
                'temperature' => 0.6
            ];
        }

        if ($is_qwen3_5) {
            if ($profile === 'agentic') {
                return [
                    'profile' => 'qwen3.5-agentic',
                    'temperature' => 0.3
                ];
            }
            if ($profile === 'reasoning') {
                return [
                    'profile' => 'qwen3.5-thinking',
                    'temperature' => 0.6
                ];
            }
            if ($profile === 'creative') {
                return [
                    'profile' => 'qwen3.5-creative',
                    'temperature' => 1.0
                ];
            }

            return [
                'profile' => 'qwen3.5-non-thinking',
                'temperature' => 0.7
            ];
        }

        if ($is_qwen3) {
            if ($profile === 'agentic') {
                return [
                    'profile' => 'qwen3-agentic',
                    'temperature' => 0.4
                ];
            }

            return [
                'profile' => 'qwen3-default',
                'temperature' => 0.7
            ];
        }

        if ($is_gpt_oss) {
            if ($profile === 'agentic') {
                return [
                    'profile' => 'gpt-oss-agentic',
                    'temperature' => 0.3
                ];
            }

            return [
                'profile' => 'gpt-oss-default',
                'temperature' => 1.0
            ];
        }

        if ($profile === 'agentic') {
            return [
                'profile' => 'agentic-default',
                'temperature' => 0.3
            ];
        }

        return [
            'profile' => 'default',
            'temperature' => 1.0
        ];
    }

    private function runPodTestBatch(array $pod): array
    {
        echo '----------------------------------------' . PHP_EOL;
        echo '----------------------------------------' . PHP_EOL;

        $prompts = $this->buildPrompts($pod);
        $mcp_servers = $this->buildMcpServers();
        $summary = [];
        $pod_total_time = 0.0;
        $pod_request_count = 0;
        $total_requests = 0;
        $total_successful_requests = 0;

        foreach ($prompts as $prompt) {
            $uses_mcp = $prompt[1] === true;
            $request_timeout = $prompt[3];
            $sampling_profile = $this->inferSamplingProfile($prompt[0], $uses_mcp);
            $sampling_configuration = $this->getSamplingConfiguration($pod['model_id'], $sampling_profile);
            $summary_key =
                $pod['model_id'] .
                '|' .
                (($pod['gpu_name'] ?? '') !== '' ? $pod['gpu_name'] : '-') .
                '|' .
                ($uses_mcp ? 'with_mcp' : 'without_mcp') .
                '|' .
                $sampling_configuration['profile'];
            if (!isset($summary[$summary_key])) {
                $summary[$summary_key] = [
                    'model_id' => $pod['model_id'],
                    'gpu_name' => $pod['gpu_name'] ?? null,
                    'mcp_mode' => $uses_mcp ? 'with_mcp' : 'without_mcp',
                    'sampling_profile' => $sampling_configuration['profile'],
                    'requests' => 0,
                    'successful_requests' => 0,
                    'time' => 0.0,
                    'output_tokens' => 0
                ];
            }
            echo 'ℹ️ Testing ' .
                $this->getPodLogLabel($pod) .
                ' (' .
                ($uses_mcp ? 'with MCP' : 'without MCP') .
                ')...' .
                PHP_EOL;
            echo '----------------------------------------' . PHP_EOL;
            __log_begin();
            echo 'ℹ️ Request: ' . __truncate_string(__remove_newlines($prompt[0]), 50) . PHP_EOL;
            echo 'ℹ️ Sampling profile: ' . $sampling_configuration['profile'] . PHP_EOL;
            echo 'ℹ️ Sampling values: temp=' . $sampling_configuration['temperature'] . PHP_EOL;
            echo 'ℹ️ Timeout: ' . $request_timeout . 's' . PHP_EOL;
            $ai = aihelper::create(
                provider: 'lmstudio',
                model: $pod['model_id'],
                temperature: $sampling_configuration['temperature'],
                timeout: $request_timeout,
                api_key: $pod['api_key'] ?? null,
                log: $this->call_log_file,
                max_tries: 1,
                mcp_servers: $uses_mcp ? $mcp_servers : null,
                session_id: null,
                history: [],
                stream: true,
                url: $pod['url'] . '/v1'
            );
            ob_start(fn($buffer) => '');
            $result = $ai->ask($prompt[0]);
            ob_end_clean();
            $successful =
                $result['success'] !== false && !__nx($result['response']) && $prompt[2]($result['response']) !== false;
            if ($successful === false) {
                echo '⛔ Response failed: ' . json_encode(__remove_newlines($result['response'])) . PHP_EOL;
            } else {
                echo '✅ Response: ' .
                    __truncate_string(__remove_newlines($result['response']), 50) .
                    ' (' .
                    mb_strlen($result['response']) .
                    ' chars)' .
                    PHP_EOL;
            }
            $time = __log_end(null, false)['time'];
            $pod_total_time += $time;
            $pod_request_count++;
            $total_requests++;
            $summary[$summary_key]['requests']++;
            $summary[$summary_key]['time'] += $time;
            $summary[$summary_key]['output_tokens'] += (int) ($result['output_tokens'] ?? 0);
            if ($successful) {
                $total_successful_requests++;
                $summary[$summary_key]['successful_requests']++;
            }
            $tokens_per_second =
                $time > 0 && !empty($result['output_tokens']) ? round($result['output_tokens'] / $time, 1) : null;
            echo 'ℹ️ Time: ' .
                round($time, 2) .
                's' .
                ($tokens_per_second !== null ? ' · ' . $tokens_per_second . ' tok/s' : '') .
                PHP_EOL;
        }

        $average = $pod_request_count > 0 ? $pod_total_time / $pod_request_count : 0;
        echo '----------------------------------------' . PHP_EOL;
        echo 'ℹ️ Average time: ' . round($average, 2) . 's' . PHP_EOL;

        return [
            'summary' => $summary,
            'total_requests' => $total_requests,
            'total_successful_requests' => $total_successful_requests,
            'total_time' => $pod_total_time
        ];
    }

    private function mergeSummary(array $worker_summary): void
    {
        foreach ($worker_summary as $summary_key => $summary_value) {
            if (!isset($this->summary[$summary_key])) {
                $this->summary[$summary_key] = $summary_value;
                continue;
            }
            $this->summary[$summary_key]['requests'] += $summary_value['requests'];
            $this->summary[$summary_key]['successful_requests'] += $summary_value['successful_requests'];
            $this->summary[$summary_key]['time'] += $summary_value['time'];
            $this->summary[$summary_key]['output_tokens'] += $summary_value['output_tokens'];
        }
    }

    private function runParallelBrowserTest(): void
    {
        echo '========================================' . PHP_EOL;
        echo '🌐 Parallel Browser Test' . PHP_EOL;
        echo '========================================' . PHP_EOL;

        if (empty($this->pods)) {
            echo '⛔ No pods available.' . PHP_EOL;
            die();
        }

        $pod = $this->pods[0];
        $mcp_servers = $this->buildBrowserMcpServers();

        if (empty($mcp_servers)) {
            echo '⛔ No browser MCP server configured (needs /api/browser in URL).' . PHP_EOL;
            die();
        }

        $prompt =
            'Dir stehen MCP-Tools fuer den Browser zur Verfuegung. ' .
            'Arbeite strikt sequentiell und fuehre immer nur den naechsten noetigen Schritt aus. ' .
            'Rufe den jeweils noetigen Tool-Call direkt auf und kuendige ihn nicht erst in Text an. ' .
            'Gib vor dem abschliessenden Ergebnis keinen erklaerenden Fliesstext aus. ' .
            'Oeffne mit browser_navigate die Seite https://www.wikipedia.org. ' .
            'Lies danach mit browser_snapshot den Inhalt der Seite. ' .
            'Extrahiere den Titel des neuesten News-Beitrags aus dem "In the news"-Bereich. ' .
            'Schliesse anschliessend den Browser sauber mit browser_close_browser. ' .
            'Gib erst ganz am Ende ausschliesslich den extrahierten Titel aus, ohne weiteren Text.';

        $sampling_configuration = $this->getSamplingConfiguration($pod['model_id'], 'agentic');

        echo 'ℹ️ Pod: ' . $this->getPodLogLabel($pod) . PHP_EOL;
        echo 'ℹ️ Sampling profile: ' . $sampling_configuration['profile'] . PHP_EOL;
        echo '----------------------------------------' . PHP_EOL;

        __log_begin();

        $ai = aihelper::create(
            provider: 'lmstudio',
            model: $pod['model_id'],
            temperature: $sampling_configuration['temperature'],
            timeout: 300,
            api_key: $pod['api_key'] ?? null,
            log: $this->call_log_file,
            max_tries: 1,
            mcp_servers: $mcp_servers,
            session_id: null,
            history: [],
            stream: true,
            url: $pod['url'] . '/v1'
        );

        ob_start(fn($buffer) => '');
        $result = $ai->ask($prompt);
        ob_end_clean();

        $successful = $result['success'] !== false && !__nx($result['response']);
        $time = __log_end(null, false)['time'];
        $tokens_per_second =
            $time > 0 && !empty($result['output_tokens']) ? round($result['output_tokens'] / $time, 1) : null;

        if ($successful) {
            echo '✅ Response: ' .
                __truncate_string(__remove_newlines($result['response']), 80) .
                ' (' .
                mb_strlen($result['response']) .
                ' chars)' .
                PHP_EOL;
        } else {
            echo '⛔ Failed: ' . json_encode(__remove_newlines($result['response'])) . PHP_EOL;
        }

        echo 'ℹ️ Time: ' .
            round($time, 2) .
            's' .
            ($tokens_per_second !== null ? ' · ' . $tokens_per_second . ' tok/s' : '') .
            PHP_EOL;
    }

    private function printSummary(): void
    {
        echo PHP_EOL;
        echo '========================================' . PHP_EOL;
        echo '📊 Summary' . PHP_EOL;
        echo '========================================' . PHP_EOL;
        echo 'ℹ️ Runs: ' . $this->run_count . PHP_EOL;
        echo 'ℹ️ Total requests: ' . $this->total_requests . PHP_EOL;
        echo 'ℹ️ Successful requests: ' . $this->total_successful_requests . '/' . $this->total_requests . PHP_EOL;
        echo 'ℹ️ Average time per request: ' .
            ($this->total_requests > 0 ? round($this->total_time / $this->total_requests, 2) : 0) .
            's' .
            PHP_EOL;
        echo '----------------------------------------' . PHP_EOL;
        foreach ($this->summary as $summary_value) {
            $average_time = $summary_value['requests'] > 0 ? $summary_value['time'] / $summary_value['requests'] : 0;
            $average_tps =
                $summary_value['time'] > 0 ? round($summary_value['output_tokens'] / $summary_value['time'], 1) : null;
            echo 'ℹ️ ' .
                $summary_value['model_id'] .
                (($summary_value['gpu_name'] ?? '') !== '' ? ' [' . $summary_value['gpu_name'] . ']' : '') .
                ' (' .
                ($summary_value['mcp_mode'] === 'with_mcp' ? 'with MCP' : 'without MCP') .
                ', ' .
                $summary_value['sampling_profile'] .
                '): ' .
                $summary_value['successful_requests'] .
                '/' .
                $summary_value['requests'] .
                ' ok, avg ' .
                round($average_time, 2) .
                's' .
                ($average_tps !== null ? ', ' . $average_tps . ' tok/s' : '') .
                PHP_EOL;
        }
        echo '========================================' . PHP_EOL;
    }
}

$obj = new RunpodTestRunner();
$obj->init();
