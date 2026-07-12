import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/services/telemetry_bus.dart';
import 'core/services/voice_handshake_engine.dart';
import 'core/services/local_server_service.dart';
import 'core/services/js_agent_registry.dart';
import 'presentation/screens/ambient_hub.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  debugPrint('[Main] Core engines pre-initialized. Voice State: ${voiceEngine.state}');

  // Pre-initialize Shelf Local Edge Server
  final localServer = container.read(localServerProvider);
  await localServer.startServer();
  debugPrint('[Main] Local Edge Server initialized. Address: ${localServer.serverAddress}');

  // Load Javascript agents from sovereign vault (MS-JS-BRIDGE-AGT1)
  final jsRegistry = container.read(jsAgentRegistryProvider);
  await jsRegistry.seedCoreAgentsIfMissing(); // MS-CORE-JS-MIGRATION: Calculator + DrivingCoach as C2 JS agents
  await jsRegistry.seedDemoAgentIfMissing();
  final jsAgentCount = await jsRegistry.loadAndRegisterAgents();
  debugPrint('[Main] JS Bridge: $jsAgentCount vault agent(s) registered.');

  // Inject dummy telematic records into the SQLite Vault every 3 seconds
  // This simulates the user carrying the device.
  Timer.periodic(const Duration(seconds: 3), (timer) {
    final lat = 28.6139 + (DateTime.now().millisecond / 10000.0);
    final lon = 77.2090 + (DateTime.now().microsecond / 1000000.0);
    // Simulating variance in accelerometer reading (simulating "Walking" noise)
    final accZ = 9.8 + (DateTime.now().millisecond % 10) / 5.0;
    
    telemetryBus.addRecord(
      latitude: lat,
      longitude: lon,
      accelerometerZ: accZ,
      compassDirection: 180.0,
    );
  });

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