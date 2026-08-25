import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'sql_query_guard.dart';
import 'telemetry_bus.dart';
import 'telemetry_collector.dart';
import 'vault_build_stamp.dart';
import 'vault_dashboard_url.dart';
import 'mcp_handler_service.dart';

class LocalServerService extends ChangeNotifier {
  static const int defaultPort = 8080;
  static const String pairHeader = 'x-aur-pair';

  /// Exact content of the standalone stdio-to-HTTP MCP proxy script.
  static const String mcpProxyPyContent = '''#!/usr/bin/env python3
import sys
import json
import urllib.request
import argparse

def log(msg):
    # Print to stderr so it doesn't corrupt MCP stdio protocol on stdout
    print(msg, file=sys.stderr, flush=True)

def main():
    parser = argparse.ArgumentParser(description="MCP Proxy for Project Aur Bhai")
    parser.add_argument("--url", required=True, help="The Local Edge Server MCP URL (e.g. http://192.168.1.5:8080/api/mcp)")
    parser.add_argument("--token", required=True, help="The Pairing Token (e.g. 4F2A89)")
    args = parser.parse_args()

    headers = {
        "Content-Type": "application/json",
        "x-aur-pair": args.token
    }

    log(f"Starting MCP Proxy forwarding to {args.url}")

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        
        line = line.strip()
        if not line:
            continue
            
        try:
            req_data = json.loads(line)
        except json.JSONDecodeError:
            log("Warning: Received invalid JSON on stdin")
            continue

        try:
            req = urllib.request.Request(
                args.url,
                data=json.dumps(req_data).encode("utf-8"),
                headers=headers,
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=30) as response:
                resp_text = response.read().decode("utf-8")
                sys.stdout.write(resp_text + "\\n")
                sys.stdout.flush()
        except Exception as e:
            log(f"Error forwarding request: {e}")
            error_response = {
                "jsonrpc": "2.0",
                "id": req_data.get("id"),
                "error": {
                    "code": -32603,
                    "message": f"Proxy Error: {e}"
                }
            }
            sys.stdout.write(json.dumps(error_response) + "\\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
''';

  final Ref _ref;
  HttpServer? _server;
  final Router _router = Router();
  final Map<String, Response Function(Request)> _dynamicRoutes = {};
  final List<StreamController<List<int>>> _sseClients = [];
  String? _lanIp;
  bool _disposed = false;

  /// Broadcasts a dashboard navigation event to all connected web hub browser tabs.
  void broadcastDashboardOpen(String dashboardKey) {
    final cleanKey = dashboardKey.trim();
    final url = cleanKey.startsWith('/vault/') ? cleanKey : '/vault/$cleanKey';
    final payload = jsonEncode({'action': 'open_dashboard', 'url': url});
    final pad = ' ' * 4096;
    final raw = utf8.encode('data: $payload\n: pad $pad\n\n');
    for (final client in List.of(_sseClients)) {
      if (!client.isClosed) {
        client.add(raw);
      }
    }
    debugPrint(
      '[LocalServer] Broadcasted open_dashboard event to ${_sseClients.length} web clients: $url',
    );
  }

  /// When false (default), non-loopback clients get 403.
  bool _lanExposureEnabled = false;
  String _pairingToken = '';

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String? get lanIp => _lanIp;
  bool get lanExposureEnabled => _lanExposureEnabled;
  String get pairingToken => _pairingToken;

  String get host {
    if (!isRunning) return '—';
    if (_lanIp != null) return _lanIp!;
    return '0.0.0.0';
  }

  String get statusLabel => isRunning ? 'ACTIVE' : 'OFFLINE';

  String get localhostAddress =>
      isRunning ? 'http://localhost:${_server!.port}' : 'Offline';

  String get lanServerAddress {
    if (!isRunning) return 'Offline';
    if (_lanIp != null) return 'http://$_lanIp:${_server!.port}';
    return localhostAddress;
  }

  String get serverAddress => lanServerAddress;

  String get statusUrl => '$serverAddress/api/status';

  /// Full URL for a vault asset. [key] must be non-empty (never bare server root).
  String vaultUrl(String key) {
    final k = normalizeVaultKeyForUrl(key);
    var url = '$serverAddress/vault/$k';
    if (_lanExposureEnabled && _pairingToken.isNotEmpty) {
      url += '?pair=$_pairingToken';
    }
    assert(
      isVaultDashboardUrl(url),
      'vaultUrl produced non-dashboard URL: $url',
    );
    return url;
  }

  static const List<String> coreEndpoints = [
    'GET /',
    'GET /api/status',
    'POST /api/query',
    'GET /vault/<key>',
    'GET /sw.js',
  ];

  /// Returned when a browser requests a missing SW — unregisters stuck workers.
  static const String killerServiceWorkerJs = '''
/* Aur Bhai killer SW — missing vault SW; uninstall and clear caches */
self.addEventListener('install', (event) => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch (_) {}
    try {
      await self.registration.unregister();
    } catch (_) {}
    try {
      const clients = await self.clients.matchAll({ type: 'window' });
      for (const c of clients) {
        if (c.navigate) c.navigate(c.url);
      }
    } catch (_) {}
  })());
});
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
''';

  LocalServerService(this._ref) {
    _pairingToken = _generatePairToken();
    _setupCoreRoutes();
  }

  void setLanExposureEnabled(bool enabled) {
    if (_lanExposureEnabled == enabled) return;
    _lanExposureEnabled = enabled;
    if (enabled) {
      _pairingToken = _generatePairToken();
    }
    if (!_disposed) notifyListeners();
    debugPrint(
      '[LocalServer] LAN exposure ${enabled ? "ON (pair=$_pairingToken)" : "OFF"}',
    );
    // Persist for next app launch (ignore errors in headless test runners).
    try {
      SharedPreferences.getInstance().then((prefs) {
        prefs.setBool('lan_exposure_enabled', enabled);
      }).catchError((dynamic _) {});
    } catch (_) {}
  }

  /// Restores the LAN exposure flag from SharedPreferences.
  Future<void> _loadPersistedLanSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool('lan_exposure_enabled');
      if (stored != null && stored != _lanExposureEnabled) {
        _lanExposureEnabled = stored;
        if (stored) _pairingToken = _generatePairToken();
        debugPrint('[LocalServer] Restored LAN exposure=$stored from prefs');
      }
    } catch (e) {
      debugPrint('[LocalServer] Could not load LAN pref: $e');
    }
  }

  void rotatePairingToken() {
    _pairingToken = _generatePairToken();
    if (!_disposed) notifyListeners();
  }

  static String _generatePairToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// Loopback always allowed (or requests from device's own LAN IP). LAN requires exposure + matching pair token.
  Response? _authorizeLan(Request request) {
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final remote = info?.remoteAddress;
    final isLoopback = remote == null ||
        remote.isLoopback ||
        (_lanIp != null && remote.address == _lanIp);
    if (isLoopback) return null;

    if (!_lanExposureEnabled) {
      return Response.forbidden(
        jsonEncode({
          'success': false,
          'error':
              'LAN access disabled. Enable in Settings → Local Edge Server.',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final presented = _presentedPairToken(request);
    if (presented != _pairingToken) {
      return Response(
        401,
        body: jsonEncode({
          'success': false,
          'error':
              'Pairing required. Open vault URL with ?pair=CODE or send header $pairHeader',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
    return null;
  }

  String _presentedPairToken(Request request) {
    final header =
        request.headers[pairHeader] ?? request.headers['X-Aur-Pair'] ?? '';
    if (header.isNotEmpty) return header.trim();
    final query = request.url.queryParameters['pair'] ?? '';
    if (query.isNotEmpty) return query.trim();
    final cookie = request.headers['cookie'] ?? '';
    for (final part in cookie.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 && kv[0] == 'aur_pair') return kv[1].trim();
    }
    return '';
  }

  Map<String, String> _pairCookieHeaders(Request request) {
    final q = request.url.queryParameters['pair'] ?? '';
    if (q.isNotEmpty && q == _pairingToken) {
      return {
        'Set-Cookie': 'aur_pair=$_pairingToken; Path=/; SameSite=Lax; HttpOnly',
      };
    }
    return const {};
  }

  static Future<String?> resolveLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('lo') || name == 'loopback') continue;
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          return addr.address;
        }
      }
    } catch (e) {
      debugPrint('[LocalServer] LAN IP resolution failed: $e');
    }
    return null;
  }

  void _setupCoreRoutes() {
    // Tool download route for zero-repo external developer setup
    _router.get('/tool/mcp_proxy.py', (Request request) {
      return Response.ok(
        mcpProxyPyContent,
        headers: {
          'Content-Type': 'text/x-python; charset=utf-8',
          'Content-Disposition': 'attachment; filename="mcp_proxy.py"',
          'Cache-Control': 'no-cache',
        },
      );
    });

    // Developer Setup Portal for MCP IDE Configuration (Approach A)
    _router.get('/dev', (Request request) {
      final effectiveIp = _lanIp ?? '127.0.0.1';
      final effectivePort = _server?.port ?? defaultPort;
      final mcpUrl = 'http://$effectiveIp:$effectivePort/api/mcp';
      final pairToken = _pairingToken;
      final body = '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aur Bhai // Developer Setup Portal (MCP)</title>
<style>
:root{--bg:#090d16;--card:#111827;--border:#1f293d;--accent:#38bdf8;--text:#f8fafc;--muted:#94a3b8;--code-bg:#030712}
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
body{background:var(--bg);color:var(--text);padding:24px;line-height:1.5}
.container{max-width:860px;margin:0 auto}
header{border-bottom:1px solid var(--border);padding-bottom:18px;margin-bottom:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px}
h1{font-size:22px;font-weight:800;display:flex;align-items:center;gap:8px}
.badge{background:rgba(56,189,248,0.15);color:var(--accent);border:1px solid rgba(56,189,248,0.3);padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:20px}
.card h2{font-size:16px;margin-bottom:12px;color:var(--text)}
.btn{background:var(--accent);color:#030712;border:none;padding:9px 16px;border-radius:8px;font-size:13px;font-weight:700;cursor:pointer;display:inline-flex;align-items:center;gap:6px;text-decoration:none}
.btn:hover{opacity:0.9}
.btn-sec{background:var(--card);color:var(--text);border:1px solid var(--border);padding:8px 14px;border-radius:8px;font-size:12px;font-weight:600;cursor:pointer}
.btn-sec:hover{border-color:var(--accent)}
pre{background:var(--code-bg);border:1px solid var(--border);border-radius:8px;padding:14px;color:#a5f3fc;font-family:monospace;font-size:13px;overflow-x:auto;position:relative;margin:10px 0}
.copy-btn{position:absolute;top:8px;right:8px;background:rgba(255,255,255,0.1);border:1px solid var(--border);color:var(--text);padding:4px 8px;border-radius:4px;font-size:11px;cursor:pointer}
.copy-btn:hover{background:var(--accent);color:#030712}
table{width:100%;border-collapse:collapse;margin-top:10px;font-size:13px}
th,td{padding:8px 12px;border:1px solid var(--border);text-align:left}
th{background:rgba(255,255,255,0.03);color:var(--muted)}
.toast{position:fixed;bottom:20px;right:20px;background:var(--card);border:1px solid var(--accent);color:var(--text);padding:10px 16px;border-radius:8px;font-size:13px;display:none}
</style></head><body>
<div class="container">
<header>
<div><h1><span>🛠️</span> Aur Bhai // Developer Portal</h1><p style="color:var(--muted);font-size:13px">Remote Agent Authoring via Model Context Protocol (MCP)</p></div>
<span class="badge">ACTIVE SERVER</span>
</header>
<div class="card">
<h2>1. Download MCP Proxy Adapter (No Repo Access Needed)</h2>
<p style="color:var(--muted);font-size:13px;margin-bottom:14px">External contributors only need this single-file Python script to bridge their IDE to this phone over local Wi-Fi.</p>
<a href="/tool/mcp_proxy.py" class="btn" download="mcp_proxy.py">⬇️ Download mcp_proxy.py</a>
</div>
<div class="card">
<h2>2. IDE Configuration</h2>
<p style="color:var(--muted);font-size:13px">Paste the configuration below into your desktop IDE settings.</p>
<h3 style="font-size:13px;margin-top:14px;color:var(--accent)">Google Antigravity (~/.gemini/config/mcp_config.json)</h3>
<pre id="antigravity-cfg">{
  "mcpServers": {
    "aur-bhai-phone": {
      "command": "python",
      "args": ["mcp_proxy.py", "--url", "$mcpUrl", "--token", "$pairToken"]
    }
  }
}<button class="copy-btn" onclick="copySnippet('antigravity-cfg')">Copy</button></pre>
<h3 style="font-size:13px;margin-top:14px;color:var(--accent)">Cursor / Claude Desktop</h3>
<pre id="cursor-cfg">{
  "mcpServers": {
    "aur-bhai": {
      "command": "python",
      "args": ["path/to/mcp_proxy.py", "--url", "$mcpUrl", "--token", "$pairToken"]
    }
  }
}<button class="copy-btn" onclick="copySnippet('cursor-cfg')">Copy</button></pre>
</div>
<div class="card">
<h2>3. Available MCP Tools</h2>
<table>
<tr><th>Tool</th><th>Description</th></tr>
<tr><td><code>mcp_list_agents</code></td><td>Lists installed Bhai Code agents in Sovereign Vault</td></tr>
<tr><td><code>mcp_read_agent</code></td><td>Reads script, schema, and HTML assets for an agent</td></tr>
<tr><td><code>mcp_deploy_agent</code></td><td>Hot-deploys updated JavaScript/HTML into phone vault</td></tr>
<tr><td><code>mcp_run_agent</code></td><td>Executes agent live in phone QuickJS sandbox</td></tr>
<tr><td><code>mcp_query_telemetry</code></td><td>Executes read-only SQL query on device telemetry</td></tr>
</table>
</div>
</div>
<div class="toast" id="toast">Copied to clipboard!</div>
<script>
function copySnippet(id){
  const el = document.getElementById(id);
  const text = el.innerText.replace("Copy", "").trim();
  navigator.clipboard.writeText(text);
  const t = document.getElementById("toast");
  t.style.display = "block";
  setTimeout(()=>{t.style.display="none"}, 2500);
}
</script>
</body></html>''';
      return Response.ok(
        body,
        headers: {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'no-store',
        },
      );
    });

    // Server-Sent Events (SSE) Stream for real-time dashboard updates & voice cross-device switching
    _router.get('/api/events', (Request request) {
      final denied = _authorizeLan(request);
      if (denied != null) return denied;

      late StreamController<List<int>> controller;

      controller = StreamController<List<int>>(
        onListen: () {
          _sseClients.add(controller);
          final pad = ' ' * 4096;
          controller.add(utf8.encode(': connected\n: pad $pad\n\n'));
        },
        onCancel: () {
          _sseClients.remove(controller);
        },
      );

      return Response.ok(
        controller.stream,
        headers: {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-cache, no-transform',
          'Connection': 'keep-alive',
          'Access-Control-Allow-Origin': '*',
        },
        context: {'shelf.io.buffer_output': false},
      );
    });

    // Unified Web Hub (root landing page)
    _router.get('/', (Request request) async {
      try {
        final bus = _ref.read(telemetryBusProvider);
        final dashboards = await bus.listVaultEntries(mimeType: 'text/html');
        final cards = dashboards.map((d) {
          final key = d['key'] ?? '';
          final build = d['build_id'] ?? '';
          final href =
              '/vault/${key.split('/').map(Uri.encodeComponent).join('/')}';
          final name = key.replaceAll('.html', '').toUpperCase();
          final buildBadge = build.isNotEmpty
              ? '<span class="badge">build ${_htmlEscape(build)}</span>'
              : '';
          return '<a href="$href" class="dash-card"><div class="dash-icon">📊</div><div class="dash-info"><h3>${_htmlEscape(name)}</h3><p>/vault/${_htmlEscape(key)}</p></div>$buildBadge</a>';
        }).join('\n');

        final body = '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aur Bhai // Unified Web Hub</title>
<style>
:root{--bg:#090d16;--card:#111827;--border:#1f293d;--accent:#38bdf8;--text:#f8fafc;--muted:#94a3b8}
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
body{background:var(--bg);color:var(--text);padding:24px;line-height:1.5}
.container{max-width:900px;margin:0 auto}
header{border-bottom:1px solid var(--border);padding-bottom:18px;margin-bottom:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px}
h1{font-size:24px;font-weight:800;display:flex;align-items:center;gap:10px}
.badge{background:rgba(56,189,248,0.15);color:var(--accent);border:1px solid rgba(56,189,248,0.3);padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin-bottom:24px}
.dash-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:18px;text-decoration:none;color:var(--text);display:flex;align-items:center;gap:14px;transition:all 0.2s}
.dash-card:hover{border-color:var(--accent);transform:translateY(-2px);background:rgba(56,189,248,0.05)}
.dash-icon{font-size:24px;background:rgba(255,255,255,0.05);padding:10px;border-radius:10px}
.dash-info h3{font-size:15px;font-weight:700}
.dash-info p{color:var(--muted);font-size:12px;margin-top:2px}
.dev-banner{background:linear-gradient(135deg,rgba(56,189,248,0.1),rgba(17,24,39,1));border:1px solid var(--accent);border-radius:12px;padding:20px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:16px}
.btn{background:var(--accent);color:#030712;border:none;padding:10px 18px;border-radius:8px;font-size:13px;font-weight:700;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;gap:6px}
.btn:hover{opacity:0.9}
.empty-state{text-align:center;padding:40px 20px;color:var(--muted);background:var(--card);border:1px dashed var(--border);border-radius:12px}
</style></head><body>
<div class="container">
<header>
<div><h1><span>📱</span> Aur Bhai // Web Hub</h1><p style="color:var(--muted);font-size:13px">Live Sovereign Dashboards & Local Edge Server</p></div>
<span class="badge">EDGE ACTIVE</span>
</header>
<h2 style="font-size:16px;margin-bottom:14px">Active Vault Dashboards</h2>
${dashboards.isEmpty ? '<div class="empty-state"><p>No dashboards published yet. Run a Bro Code (e.g. NoteTaker, Telemeter, IWish) to generate one.</p></div>' : '<div class="grid">$cards</div>'}
<div class="dev-banner">
<div><h3 style="font-size:16px;font-weight:700">Developer MCP Bridge Portal</h3><p style="color:var(--muted);font-size:13px;margin-top:4px">Author & hot-reload Bhai Code directly from desktop IDEs without repo access.</p></div>
<a href="/dev" class="btn">Open Developer Portal 🛠️</a>
</div>
</div>
<script>
// Auto-switch dashboard when user speaks into phone
try {
  const evtSource = new EventSource("/api/events");
  evtSource.onmessage = function(event) {
    if (!event.data) return;
    try {
      const data = JSON.parse(event.data);
      if (data.action === "open_dashboard" && data.url) {
        window.location.href = data.url;
      }
    } catch(e) {}
  };
} catch(e) {}
</script>
</body></html>''';
        return Response.ok(
          body,
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-store',
          },
        );
      } catch (e) {
        return Response.internalServerError(body: 'Edge index error: $e');
      }
    });

    _router.get('/api/status', (Request request) {
      return Response.ok(
        jsonEncode({
          'status': 'active',
          'engine': 'Project Aur Bhai',
          'systemTime': DateTime.now().toIso8601String(),
          'lanIp': _lanIp,
          'port': _server?.port,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    });

    _router.post('/api/query', (Request request) async {
      final denied = _authorizeLan(request);
      if (denied != null) return denied;
      try {
        final body = await request.readAsString();
        final payload = jsonDecode(body);
        final sql = payload['sql'] as String;
        final args = payload['arguments'] as List<dynamic>?;

        final telemetryBus = _ref.read(telemetryBusProvider);
        final results = await telemetryBus.executeQuery(sql, args);

        return Response.ok(
          jsonEncode({'success': true, 'data': results}),
          headers: {'Content-Type': 'application/json'},
        );
      } on SqlQueryRejected catch (e) {
        return Response(
          400,
          body: jsonEncode({'success': false, 'error': e.message}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'success': false, 'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    _router.post('/api/mcp', (Request request) async {
      final denied = _authorizeLan(request);
      if (denied != null) return denied;
      try {
        final body = await request.readAsString();
        final payload = jsonDecode(body) as Map<String, dynamic>;
        
        final handler = _ref.read(mcpHandlerServiceProvider);
        final result = await handler.handleJsonRpc(payload);
        
        return Response.ok(
          jsonEncode(result),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({
            'jsonrpc': '2.0',
            'error': {'code': -32603, 'message': e.toString()}
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // Root /sw.js — common bad register path; kill stuck workers.
    _router.get('/sw.js', (Request request) {
      return _killerServiceWorkerResponse();
    });

    _router.get('/vault/<key>', (Request request, String key) async {
      final denied = _authorizeLan(request);
      if (denied != null) return denied;
      try {
        final telemetryBus = _ref.read(telemetryBusProvider);
        final asset = await telemetryBus.readVaultData(key);

        if (asset == null) {
          if (_isServiceWorkerKey(key)) {
            return _killerServiceWorkerResponse();
          }
          return Response.notFound(
            'Asset "$key" not found in Sovereign Vault.',
          );
        }

        final mime = _vaultMime(key, asset['mime_type']);
        final hash = asset['content_hash'] ?? vaultContentHash(asset['value']!);
        final buildId =
            asset['build_id'] ??
            resolveVaultBuildId(
              value: asset['value']!,
              contentHash: asset['content_hash'],
              updatedAtIso: asset['updated_at'],
            );
        final isHtml =
            mime.contains('html') || key.toLowerCase().endsWith('.html');
        final raw = asset['value'] ?? '';
        if (isHtml && raw.trim().length < 40) {
          return Response(
            502,
            body:
                'Vault HTML "$key" is empty or unusable '
                '(${raw.trim().length} chars). Re-run the Bro Code / APPLY so '
                'System.writeVault publishes a full dashboard document. '
                'build=$buildId',
            headers: {
              'Content-Type': 'text/plain; charset=utf-8',
              'Cache-Control': 'no-store',
              'X-Aur-Build': _httpHeaderSafe(buildId),
            },
          );
        }
        final body = isHtml ? injectHtmlBuildStamp(raw, buildId) : raw;

        return Response.ok(
          body,
          headers: {
            'Content-Type': mime,
            'ETag': '"$hash"',
            // HTTP headers must be ASCII — pretty build id uses '·'.
            'X-Aur-Build': _httpHeaderSafe(buildId),
            if (isHtml) 'Cache-Control': 'no-store',
            // Helps browsers drop stuck execution contexts / rogue SWs.
            if (isHtml) 'Clear-Site-Data': '"executionContexts"',
            // Do NOT allow '/' — a bad SW would blank the whole origin.
            // Default scope stays under /vault/ next to the script.
            if (_isManifestKey(key) && !isHtml) 'Cache-Control': 'no-cache',
            ..._pairCookieHeaders(request),
          },
        );
      } catch (e) {
        return Response.internalServerError(
          body: 'Vault asset retrieval error: $e',
        );
      }
    });

    // IMU settings endpoint — called by dashboard ⚙ popover.
    // Body: { "cadenceMs": 500, "retentionMs": 1800000 }
    _router.post('/api/imu-settings', (Request request) async {
      try {
        final body = jsonDecode(await request.readAsString()) as Map;
        final cadenceMs = (body['cadenceMs'] as num?)?.toInt();
        final retentionMs = (body['retentionMs'] as num?)?.toInt();
        final collector = _ref.read(telemetryCollectorProvider);
        if (cadenceMs != null && cadenceMs > 0) {
          collector.setImuCadence(Duration(milliseconds: cadenceMs));
        }
        if (retentionMs != null && retentionMs > 0) {
          collector.setImuRetention(Duration(milliseconds: retentionMs));
        } else if (retentionMs == 0) {
          // 0 = never purge (∞ mode)
          collector.setImuRetention(const Duration(days: 365));
        }
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'success': false, 'error': '$e'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    _router.all('/<ignored|.*>', (Request request) {
      final path = request.url.path;
      final dynamicHandler = _dynamicRoutes['/$path'];
      if (dynamicHandler != null) {
        return dynamicHandler(request);
      }
      return Response.notFound('Route not found on local edge server.');
    });
  }

  Future<void> startServer({int? preferredPort}) async {
    if (_server != null || _disposed) return;

    // Restore persisted LAN exposure setting before binding.
    await _loadPersistedLanSetting();

    _lanIp = await resolveLanIpv4();

    final portsToTry = preferredPort != null
        ? [preferredPort]
        : [defaultPort, 8081, 18080, 0];

    for (final tryPort in portsToTry) {
      try {
        final handler = const Pipeline()
            .addMiddleware(_lanGateMiddleware())
            .addHandler(_router.call);
        _server = await io.serve(handler, InternetAddress.anyIPv4, tryPort);
        if (!_disposed) notifyListeners();
        debugPrint(
          '[LocalServer] Shelf Edge Server listening on 0.0.0.0:${_server!.port}'
          '${_lanIp != null ? ' (LAN: http://$_lanIp:${_server!.port})' : ''}',
        );
        return;
      } catch (e) {
        debugPrint('[LocalServer] Port $tryPort unavailable: $e');
      }
    }
    debugPrint('[LocalServer] Start failed: no available port');
  }

  Future<void> refreshLanIp() async {
    if (_disposed) return;
    _lanIp = await resolveLanIpv4();
    notifyListeners();
  }

  Future<void> stopServer() async {
    if (_server == null) return;
    final active = _server;
    _server = null;
    await active!.close(force: true);
    if (!_disposed) notifyListeners();
    debugPrint('[LocalServer] Server shut down.');
  }

  void registerDynamicRoute(String path, Response Function(Request) handler) {
    _dynamicRoutes[path] = handler;
    debugPrint('[LocalServer] Registered dynamic route handler: $path');
  }

  void unregisterDynamicRoute(String path) {
    _dynamicRoutes.remove(path);
  }

  Middleware _lanGateMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        final path = request.url.path;
        // Status + killer SW + index stay reachable for discovery; data paths gated.
        final public = path.isEmpty || path == 'api/status' || path == 'sw.js';
        if (!public) {
          final denied = _authorizeLan(request);
          if (denied != null) return denied;
        }
        return inner(request);
      };
    };
  }

  static bool _isManifestKey(String key) {
    final k = key.toLowerCase();
    return k.endsWith('.webmanifest') ||
        k.endsWith('manifest.json') ||
        k.contains('manifest');
  }

  static bool _isServiceWorkerKey(String key) {
    final k = key.toLowerCase();
    return k.endsWith('.sw.js') ||
        k.contains('service-worker') ||
        k.contains('serviceworker') ||
        (k.endsWith('sw.js'));
  }

  static Response _killerServiceWorkerResponse() {
    return Response.ok(
      killerServiceWorkerJs,
      headers: {
        'Content-Type': 'application/javascript; charset=utf-8',
        'Cache-Control': 'no-store',
        'Service-Worker-Allowed': '/vault/',
      },
    );
  }

  /// Latin-1 safe token for response headers (build ids may contain '·').
  static String _httpHeaderSafe(String value) =>
      value.replaceAll('·', '-').replaceAll(RegExp(r'[^\x20-\x7E]'), '-');

  static String _vaultMime(String key, String? stored) {
    if (stored != null &&
        stored.isNotEmpty &&
        stored != 'text/plain' &&
        stored != 'application/octet-stream') {
      return stored;
    }
    if (_isManifestKey(key)) return 'application/manifest+json';
    if (_isServiceWorkerKey(key)) return 'application/javascript';
    if (key.toLowerCase().endsWith('.html')) return 'text/html';
    if (key.toLowerCase().endsWith('.json')) return 'application/json';
    if (key.toLowerCase().endsWith('.js')) return 'application/javascript';
    return stored ?? 'text/plain';
  }

  static String _htmlEscape(String s) => const HtmlEscape().convert(s);

  @override
  void dispose() {
    _disposed = true;
    for (final client in _sseClients) {
      client.close();
    }
    _sseClients.clear();
    if (_server != null) {
      _server!.close(force: true);
      _server = null;
    }
    super.dispose();
  }
}

final localServerProvider = Provider<LocalServerService>((ref) {
  final service = LocalServerService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
