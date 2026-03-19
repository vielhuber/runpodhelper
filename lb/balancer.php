<?php
// load balancer: routes each request to the pod with the lowest GPU utilization.
// gpu_util is written per-pod by the health loop (from nvidia-smi via SSH).
// tracks last_request_at for the scale-down idle decision in the health loop.
// state file path is passed via LB_STATE_FILE environment variable.

$stateFile = getenv('LB_STATE_FILE') ?: ($_SERVER['LB_STATE_FILE'] ?? '');

if ($stateFile === '' || !file_exists($stateFile)) {
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available (balancer state not initialized yet, retry in a moment)']);
    exit;
}

$fp = fopen($stateFile, 'r+');
if (!$fp) {
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Cannot open state file']);
    exit;
}

flock($fp, LOCK_EX);

$content = stream_get_contents($fp);
$state = json_decode($content, true) ?? ['pods' => []];

$pods = $state['pods'] ?? [];
if (empty($pods)) {
    flock($fp, LOCK_UN);
    fclose($fp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available yet']);
    exit;
}

// Route to pod with lowest GPU utilization; fall back to first pod if no utilization data is available yet.
$selectedIndex = 0;
$minUtil = PHP_INT_MAX;
foreach ($pods as $i => $pod) {
    $util = (int)($pod['gpu_util'] ?? -1);
    if ($util >= 0 && $util < $minUtil) {
        $minUtil = $util;
        $selectedIndex = $i;
    }
}

$state['last_request_at'] = time();

$podUrl = rtrim($pods[$selectedIndex]['url'], '/');
$requestUri = $_SERVER['REQUEST_URI'] ?? '/';

ftruncate($fp, 0);
rewind($fp);
fwrite($fp, json_encode($state, JSON_PRETTY_PRINT));
flock($fp, LOCK_UN);
fclose($fp);

// 307 preserves the request method (important for POST to LLM API endpoints)
header('Location: ' . $podUrl . $requestUri, true, 307);
