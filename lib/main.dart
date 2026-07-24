import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/services/telemetry_bus.dart';
import 'core/services/voice_handshake_engine.dart';
import 'core/services/local_server_service.dart';
import 'core/services/js_agent_registry.dart';
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
  final telemetryBus = container.read(telemetryBusProvider);
  await telemetryBus.initialize();

  final voiceEngine = container.read(voiceHandshakeProvider);
  debugPrint(
    '[Main] Core engines pre-initialized. Voice State: ${voiceEngine.state}',
  );

  // Pre-initialize Shelf Local Edge Server
  final localServer = container.read(localServerProvider);
  await localServer.startServer();
  debugPrint(
    '[Main] Local Edge Server initialized. Address: ${localServer.serverAddress}',
  );

  // Load Javascript agents from sovereign vault (MS-JS-BRIDGE-AGT1)
  final jsRegistry = container.read(jsAgentRegistryProvider);
  await jsRegistry
      .seedCoreAgentsIfMissing(); // MS-CORE-JS-MIGRATION: Calculator + DrivingCoach as C2 JS agents
  await jsRegistry.seedDemoAgentIfMissing();
  await jsRegistry
      .consumeFriendInstallQueueIfPresent(); // S15 friend fixture replay
  final jsAgentCount = await jsRegistry.loadAndRegisterAgents();
  debugPrint('[Main] JS Bridge: $jsAgentCount vault agent(s) registered.');

  // Live GPS/accel → sovereign vault starts after first UI frame (AmbientHub).
  // Sandbox / due-diligence Bro Code never receives that stream.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ProjectAurBhaiApp(),
    ),
  );
}

class ProjectAurBhaiApp extends StatelessWidget {
  const ProjectAurBhaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Project Aur Bhai',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const AmbientHubScreen(),
    );
  }
}
