import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/services/telemetry_bus.dart';
import 'core/services/voice_handshake_engine.dart';
import 'core/services/local_server_service.dart';
import 'core/services/js_agent_registry.dart';
import 'core/services/marketplace_catalog.dart';
import 'core/services/theme_service.dart';
import 'presentation/screens/ambient_hub.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Port for wake-listen FGS ↔ UI (MS-OFFLINE-WAKE).
  FlutterForegroundTask.initCommunicationPort();

  // Initialize SQLite for Windows testing (FFI required for desktop)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final container = ProviderContainer();

  // Pre-initialize Telemetry database before booting the app UI
  try {
    final telemetryBus = container.read(telemetryBusProvider);
    await telemetryBus.initialize();
  } catch (e, st) {
    debugPrint('[Main] TelemetryBus init warning: $e\n$st');
  }

  try {
    final voiceEngine = container.read(voiceHandshakeProvider);
    debugPrint(
      '[Main] Core engines pre-initialized. Voice State: ${voiceEngine.state}',
    );
  } catch (e, st) {
    debugPrint('[Main] Voice Engine init warning: $e\n$st');
  }

  // Pre-initialize Shelf Local Edge Server
  try {
    final localServer = container.read(localServerProvider);
    await localServer.startServer();
    debugPrint(
      '[Main] Local Edge Server initialized. Address: ${localServer.serverAddress}',
    );
  } catch (e, st) {
    debugPrint('[Main] Local Edge Server init warning: $e\n$st');
  }

  // Load Javascript agents from sovereign vault (MS-JS-BRIDGE-AGT1)
  try {
    final jsRegistry = container.read(jsAgentRegistryProvider);
    await jsRegistry.seedCoreAgentsIfMissing();
    await jsRegistry.consumeFriendInstallQueueIfPresent();
    final jsAgentCount = await jsRegistry.loadAndRegisterAgents();
    debugPrint('[Main] JS Bridge: $jsAgentCount vault agent(s) registered.');
  } catch (e, st) {
    debugPrint('[Main] JS Registry boot warning: $e\n$st');
  }

  // Auto-upgrade any installed seed-catalog agent whose script has changed.
  // This means users never have to delete + re-pick Telemeter etc. after updates.
  try {
    await container.read(marketplaceCatalogProvider).upgradeSeedListings();
    debugPrint('[Main] Seed catalog upgrade check complete.');
  } catch (e, st) {
    debugPrint('[Main] Seed catalog upgrade warning: $e\n$st');
  }

  // Live GPS/accel → sovereign vault starts after first UI frame (AmbientHub).
  // Sandbox / due-diligence Bro Code never receives that stream.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ProjectAurBhaiApp(),
    ),
  );
}

class ProjectAurBhaiApp extends ConsumerWidget {
  const ProjectAurBhaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeService = ref.watch(themeServiceProvider);
    return MaterialApp(
      title: 'Project Aur Bhai',
      debugShowCheckedModeBanner: false,
      theme: themeService.buildThemeData(),
      home: const AmbientHubScreen(),
    );
  }
}
