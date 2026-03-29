<?php
// load balancer: routes each request to the pod with the lowest in-flight request count.
// in_flight is incremented here per routed request and decremented by the health loop each poll cycle.
// gpu_util (written per-pod by the health loop via nvidia-smi) is used as secondary tiebreaker.
// tracks last_request_at for the scale-down idle decision in the health loop.
// state file path is passed via LB_STATE_FILE environment variable.
// a dedicated .lock file is used so both scale.php and the health loop share the same advisory lock,
// preventing the health loop's atomic mv from overwriting in_flight updates written by scale.php.

$stateFile = getenv('LB_STATE_FILE') ?: ($_SERVER['LB_STATE_FILE'] ?? '');
$lockFile  = $stateFile . '.lock';

if ($stateFile === '' || !file_exists($stateFile)) {
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available (balancer state not initialized yet, retry in a moment)']);
    exit;
}

$lockFp = fopen($lockFile, 'c');
if (!$lockFp) {
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Cannot open lock file']);
    exit;
}

flock($lockFp, LOCK_EX);

$fp = fopen($stateFile, 'r+');
if (!$fp) {
    flock($lockFp, LOCK_UN);
    fclose($lockFp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Cannot open state file']);
    exit;
}

$content = fread($fp, filesize($stateFile) ?: 1);
$state = json_decode($content, true) ?? ['pods' => []];

$pods = $state['pods'] ?? [];
if (empty($pods)) {
    flock($lockFp, LOCK_UN);
    fclose($lockFp);
    fclose($fp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available yet']);
    exit;
}

// Route to pod with lowest in-flight request count; use GPU utilization as tiebreaker.
$selectedIndex = 0;
$minScore = PHP_INT_MAX;
foreach ($pods as $i => $pod) {
    $inFlight = (int)($pod['in_flight'] ?? 0);
    $gpuUtil = (int)($pod['gpu_util'] ?? 0);
    // combine in_flight (primary) and gpu_util (secondary tiebreaker) into a single score
    $score = $inFlight * 1000 + $gpuUtil;
    if ($score < $minScore) {
        $minScore = $score;
        $selectedIndex = $i;
    }
}

$state['pods'][$selectedIndex]['in_flight'] = (int)($state['pods'][$selectedIndex]['in_flight'] ?? 0) + 1;
$state['last_request_at'] = time();

$podUrl = rtrim($pods[$selectedIndex]['url'], '/');
$requestUri = $_SERVER['REQUEST_URI'] ?? '/';

ftruncate($fp, 0);
rewind($fp);
fwrite($fp, json_encode($state, JSON_PRETTY_PRINT));
fclose($fp);
flock($lockFp, LOCK_UN);
fclose($lockFp);

// 307 preserves the request method (important for POST to LLM API endpoints)
header('Location: ' . $podUrl . $requestUri, true, 307);
