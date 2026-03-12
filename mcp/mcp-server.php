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
use Monolog\Logger;
use Monolog\Level;
use Monolog\Handler\StreamHandler;
use PhpMcp\Server\Server;
use PhpMcp\Server\Transports\StdioServerTransport;
try {
    $server = Server::make()
        ->withServerInfo('MCP Server', '1.0.0')
        ->withLogger((new Logger('mcp'))->pushHandler(new StreamHandler(__DIR__ . '/mcp-server.log', Level::Debug)))
        ->withSession('array', 60 * 60 * 8)
        ->build();
    $server->discover(basePath: __DIR__, scanDirs: ['.']);
    $server->listen(new StdioServerTransport());
} catch (\Throwable $e) {
    fwrite(STDERR, '[CRITICAL ERROR] ' . $e->getMessage() . "\n");
    die();
}
