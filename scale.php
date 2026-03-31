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

// clear cached stat so filesize() reflects the current file after an atomic mv by the health loop
clearstatcache(true, $stateFile);

$fp = fopen($stateFile, 'r+');
if (!$fp) {
    flock($lockFp, LOCK_UN);
    fclose($lockFp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Cannot open state file']);
    exit;
}

$size    = filesize($stateFile);
$content = $size > 0 ? fread($fp, $size) : '';
$state   = json_decode($content, true);

if (!is_array($state)) {
    fclose($fp);
    flock($lockFp, LOCK_UN);
    fclose($lockFp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available (state unreadable, retry in a moment)']);
    exit;
}

// filter out null/invalid entries that can appear during a concurrent atomic write
$pods = array_values(array_filter(
    $state['pods'] ?? [],
    static fn($pod): bool => is_array($pod) && isset($pod['url'])
));

if ($pods === []) {
    fclose($fp);
    flock($lockFp, LOCK_UN);
    fclose($lockFp);
    http_response_code(503);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'No pods available yet']);
    exit;
}

// Round-robin routing: cycle through pods sequentially.
// The health loop resets in_flight to 0 before scale.php can decrement it (the 307
// redirect bypasses scale.php on the way back), so score-based routing sees all pods
// at 0 and always picks the first one. A persistent round-robin index avoids this.
$lastIndex     = (int)($state['last_pod_index'] ?? -1);
$selectedIndex = ($lastIndex + 1) % count($pods);
$state['last_pod_index'] = $selectedIndex;

$pods[$selectedIndex]['in_flight'] = (int)($pods[$selectedIndex]['in_flight'] ?? 0) + 1;

// write back updated in_flight and last_request_at into state
$state['pods']            = $pods;
$state['last_request_at'] = time();

$podUrl     = rtrim($pods[$selectedIndex]['url'], '/');
$requestUri = $_SERVER['REQUEST_URI'] ?? '/';

ftruncate($fp, 0);
rewind($fp);
fwrite($fp, json_encode($state, JSON_PRETTY_PRINT));
fclose($fp);
flock($lockFp, LOCK_UN);
fclose($lockFp);

// 307 preserves the request method (important for POST to LLM API endpoints)
header('Location: ' . $podUrl . $requestUri, true, 307);
