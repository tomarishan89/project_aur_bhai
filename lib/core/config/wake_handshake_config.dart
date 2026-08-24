/// Tap / hold ack modes and free openWakeWord model catalog.
class WakeHandshakeConfig {
  WakeHandshakeConfig._();

  static const String listenAlwaysOn = 'always_on';
  static const String listenOnDemand = 'on_demand';

  static const String tapSpoken = 'Spoken Word';
  static const String tapSound = 'System Sound';
  static const String tapSilent = 'Silent';

  static const String holdHaptic = 'Haptic';
  static const String holdBeep = 'Beep';
  static const String holdSilent = 'Silent';

  static const List<String> tapAckModes = [tapSpoken, tapSound, tapSilent];
  static const List<String> holdAckModes = [holdHaptic, holdBeep, holdSilent];
  static const List<String> listenModes = [listenAlwaysOn, listenOnDemand];

  /// Default free pretrained wake (bundled in APK).
  static const String defaultWakeModelId = 'hey_jarvis';

  /// Catalog of free openWakeWord models (preference: Jarvis → Rhasspy → Mycroft).
  static const List<WakeModelSpec> wakeCatalog = [
    WakeModelSpec(
      id: 'hey_jarvis',
      label: 'Hey Jarvis',
      fileName: 'hey_jarvis_v0.1.onnx',
      assetPath: 'assets/wake/hey_jarvis_v0.1.onnx',
      downloadUrl: null,
      bundled: true,
    ),
    WakeModelSpec(
      id: 'hey_rhasspy',
      label: 'Hey Rhasspy',
      fileName: 'hey_rhasspy_v0.1.onnx',
      assetPath: null,
      downloadUrl:
          'https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/hey_rhasspy_v0.1.onnx',
      bundled: false,
    ),
    WakeModelSpec(
      id: 'hey_mycroft',
      label: 'Hey Mycroft',
      fileName: 'hey_mycroft_v0.1.onnx',
      assetPath: null,
      downloadUrl:
          'https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/hey_mycroft_v0.1.onnx',
      bundled: false,
    ),
  ];

  static const String melAssetPath = 'assets/wake/melspectrogram.onnx';
  static const String embAssetPath = 'assets/wake/embedding_model.onnx';

  static WakeModelSpec? specForId(String id) {
    for (final s in wakeCatalog) {
      if (s.id == id) return s;
    }
    return null;
  }

  static String labelForWakeModel(String id) =>
      specForId(id)?.label ?? id;

  static String normalizeWakeModelId(String? raw) {
    final id = (raw ?? '').trim().toLowerCase();
    if (specForId(id) != null) return id;
    // Migrate old Porcupine ids → default free model.
    return defaultWakeModelId;
  }

  static String normalizeTapAck(String? raw) {
    if (raw != null && tapAckModes.contains(raw)) return raw;
    if (raw == 'Spoken Word' || raw == 'System Sound' || raw == 'Silent') {
      return raw!;
    }
    return tapSpoken;
  }

  static String normalizeHoldAck(String? raw) {
    if (raw != null && holdAckModes.contains(raw)) return raw;
    return holdHaptic;
  }

  static String normalizeListenMode(String? raw) {
    if (raw == listenAlwaysOn) return listenAlwaysOn;
    // Unset / unknown → on-demand so UI does not claim Always-on while listen is off.
    return listenOnDemand;
  }
}

class WakeModelSpec {
  const WakeModelSpec({
    required this.id,
    required this.label,
    required this.fileName,
    required this.assetPath,
    required this.downloadUrl,
    required this.bundled,
  });

  final String id;
  final String label;
  final String fileName;
  final String? assetPath;
  final String? downloadUrl;
  final bool bundled;

  bool get isDownloadable => downloadUrl != null && !bundled;
}
