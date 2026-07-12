import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'telemetry_bus.dart';

class LocalServerService extends ChangeNotifier {
  static const int defaultPort = 8080;

  final Ref _ref;
  HttpServer? _server;
  final Router _router = Router();
  final Map<String, Response Function(Request)> _dynamicRoutes = {};
  String? _lanIp;
  bool _disposed = false;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String? get lanIp => _lanIp;

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

  String vaultUrl(String key) => '$serverAddress/vault/$key';

  static const List<String> coreEndpoints = [
    'GET /api/status',
    'POST /api/query',
    'GET /vault/<key>',
  ];

  LocalServerService(this._ref) {
    _setupCoreRoutes();
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
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'success': false, 'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    _router.get('/vault/<key>', (Request request, String key) async {
      try {
        final telemetryBus = _ref.read(telemetryBusProvider);
        final asset = await telemetryBus.readVaultData(key);

        if (asset == null) {
          return Response.notFound('Asset "$key" not found in Sovereign Vault.');
        }

        return Response.ok(
          asset['value'],
          headers: {'Content-Type': asset['mime_type'] ?? 'text/plain'},
        );
      } catch (e) {
        return Response.internalServerError(body: 'Vault asset retrieval error: $e');
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
        final cascade = Cascade().add(_router.call);
        _server = await io.serve(
          cascade.handler,
          InternetAddress.anyIPv4,
          tryPort,
        );
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
