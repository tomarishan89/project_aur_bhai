import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'sql_query_guard.dart';
import 'telemetry_bus.dart';
import 'vault_build_stamp.dart';
import 'vault_dashboard_url.dart';

class LocalServerService extends ChangeNotifier {
  static const int defaultPort = 8080;
  static const String pairHeader = 'x-aur-pair';

  final Ref _ref;
  HttpServer? _server;
  final Router _router = Router();
  final Map<String, Response Function(Request)> _dynamicRoutes = {};
  String? _lanIp;
  bool _disposed = false;

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
    final url = '$serverAddress/vault/$k';
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

  /// Loopback always allowed. LAN requires exposure + matching pair token.
  Response? _authorizeLan(Request request) {
    final info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final remote = info?.remoteAddress;
    final isLoopback = remote == null || remote.isLoopback;
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
    // Bare host:8080/ is not a dashboard — explain and link vault HTML keys.
    _router.get('/', (Request request) async {
      try {
        final bus = _ref.read(telemetryBusProvider);
        final dashboards = await bus.listVaultEntries(mimeType: 'text/html');
        final links = dashboards
            .map((d) {
              final key = d['key'] ?? '';
              final build = d['build_id'] ?? '';
              final href =
                  '/vault/${key.split('/').map(Uri.encodeComponent).join('/')}';
              final buildNote = build.isEmpty
                  ? ''
                  : ' <span style="color:#888">build ${_htmlEscape(build)}</span>';
              return '<li><a href="$href">${_htmlEscape(key)}</a>$buildNote</li>';
            })
            .join('\n');
        final body =
            '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aur Bhai Edge Server</title>
<style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:24px;line-height:1.45}
a{color:#7CFFB2} .muted{color:#888;font-size:14px}
</style></head><body>
<h1>Aur Bhai edge server</h1>
<p class="muted">This is the server root — not a Bro Code dashboard.
Open a vault HTML URL (<code>/vault/&lt;name.html&gt;</code>) from the app’s
<strong>Vault Dashboards</strong> panel.</p>
<p><a href="/api/status">/api/status</a></p>
<h2>Dashboards in vault</h2>
${dashboards.isEmpty ? '<p class="muted">None yet. Run a Bro Code that publishes HTML.</p>' : '<ul>$links</ul>'}
</body></html>
''';
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
