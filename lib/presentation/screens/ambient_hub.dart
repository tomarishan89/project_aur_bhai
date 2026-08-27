import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:intl/intl.dart';

import '../../core/services/voice_handshake_engine.dart';
import '../../core/services/byok_service.dart';
import '../../core/services/agent_service.dart';
import '../../core/agents/agent_base.dart';
import '../../core/agents/js_agent_adapter.dart';
import '../../core/models/lineage_entry.dart';
import '../../core/services/llm_service.dart';
import '../../core/services/llm/llm_capability_catalog.dart';
import '../../core/services/llm/llm_provider.dart';
import '../../core/services/llm/llm_provider_factory.dart';
import '../../core/services/local_server_service.dart';
import '../../core/services/js_agent_registry.dart';
import '../../core/services/conversational_session_service.dart';
import '../../core/services/agent_verification_service.dart';
import '../../core/services/device_auth_service.dart';
import '../../core/services/telemetry_bus.dart';
import '../../core/services/telemetry_collector.dart';
import '../../core/services/theme_service.dart';
import '../../core/services/vault_dashboard_url.dart';
import '../../core/services/marketplace_catalog.dart';
import '../../core/services/llm/llm_slot.dart';
import '../../core/services/app_spec.dart';
import '../../core/services/author_prompts.dart';
import '../../core/pipeline/bro_code_coding_agent.dart';
import '../../core/pipeline/authoring_trace.dart';
import '../../core/pipeline/bro_code_fixture_capture.dart';
import '../../core/pipeline/bro_code_fixture_report.dart';
import '../../core/pipeline/bro_code_workspace.dart';
import '../../core/pipeline/context_estimate.dart';
import '../widgets/context_usage_gauge.dart';
import '../widgets/due_diligence_findings_list.dart';
import '../widgets/ambient_capture_panel.dart';
import '../widgets/llm_capability_knobs.dart';
import '../widgets/llm_model_picker.dart';
import '../widgets/llm_provider_capability_notice.dart';
import '../widgets/llm_slot_editors.dart';
import '../widgets/circle_marketplace_tab.dart';
import '../widgets/bhai_code_preview_sheet.dart';
import '../widgets/sandbox_queue_tab.dart';
import '../widgets/publish_to_circle_dialog.dart';
import '../../core/config/app_config.dart';
import '../../core/config/wake_handshake_config.dart';
import '../../core/services/wake_word_service.dart';
import '../../core/services/bro_call_service.dart';
import '../../core/services/circle_registry_service.dart';
import '../../core/services/bhai_code_origin.dart';
import '../../core/services/default_mere_bhai.dart';
import '../../core/services/headset_media_keys.dart';
import '../../core/services/issue_report_service.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';

IconData _bhaiOriginIcon(String? source) {
  switch (BhaiCodeOrigin.normalize(source)) {
    case BhaiCodeOrigin.friendCircle:
      return Icons.groups_outlined;
    case BhaiCodeOrigin.pool:
      return Icons.public;
    default:
      return Icons.person_outline;
  }
}

/// Bumped after agent RUN so the Vault Dashboards banner reloads.
class VaultDashboardRefresh extends ChangeNotifier {
  int _tick = 0;
  int get tick => _tick;
  void bump() {
    _tick++;
    notifyListeners();
  }
}

final vaultDashboardRefreshProvider =
    ChangeNotifierProvider<VaultDashboardRefresh>((ref) {
      return VaultDashboardRefresh();
    });

/// Opens [url] with the platform default handler (Chrome/browser on Android).
/// Falls back to copying the URL only if no handler can launch it.
Future<void> launchInBrowser(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.hasScheme)) {
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (_) {
      // try desktop process / clipboard below
    }
  }

  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url], runInShell: true);
      return;
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
      return;
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
      return;
    }
  } catch (_) {
    // fall through to clipboard fallback
  }

  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open in an app — URL copied: $url')),
    );
  }
}

/// Opens a vault dashboard URL only — refuses server root /api/* (blank-page trap).
Future<void> launchVaultDashboard(BuildContext context, String url) async {
  final err = vaultDashboardUrlError(url);
  if (err != null) {
    debugPrint('[launchVaultDashboard] refused: $url — $err');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    return;
  }
  debugPrint('[launchVaultDashboard] $url');
  await launchInBrowser(context, url);
}

/// Promotion dialog shared by post-author listener and agent detail sheet.
Future<void> showAgentPromotionDialog(
  BuildContext context,
  WidgetRef ref,
  PendingPromotion pending, {
  VoidCallback? onPromoted,
}) async {
  final verification = ref.read(agentVerificationProvider);
  if (!context.mounted) return;

  if (pending.scan.passed) {
    final promote = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Promote Agent?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '${pending.agentName} passed due diligence. Promote to Mere Bhai?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('LATER'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'PROMOTE',
              style: TextStyle(color: Colors.greenAccent),
            ),
          ),
        ],
      ),
    );
    if (promote == true) {
      final registry = ref.read(jsAgentRegistryProvider);
      final toC3 = await verification.promoteToDueDiligence(
        registry: registry,
        agentName: pending.agentName,
        priorScan: pending.scan,
      );
      final ok =
          toC3 &&
          await verification.promoteToVerified(
            registry: registry,
            agentName: pending.agentName,
            priorScan: pending.scan,
          );
      if (context.mounted) {
        if (ok) {
          onPromoted?.call();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${pending.agentName} promoted to Mere Bhai.'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Promotion failed (need due diligence before Mere Bhai).',
              ),
            ),
          );
        }
      }
    } else {
      verification.clearPendingPromotion();
    }
    return;
  }

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (ctx) => _ForcePromoteDialog(
      pending: pending,
      onKeepAtC4: () {
        verification.clearPendingPromotion();
        Navigator.pop(ctx);
      },
      onForcePromote: () async {
        final authResult = await ref
            .read(deviceAuthServiceProvider)
            .authenticate(
              reason:
                  'Authenticate to promote ${pending.agentName} to Mere Bhai',
            );
        if (!authResult.success) {
          // Keep dialog open; caller shows inline error via return value.
          return authResult.errorMessage ??
              'Authentication cancelled or failed. Agent stays in Sabke Bhai.';
        }
        final ok = await verification.promoteToVerified(
          registry: ref.read(jsAgentRegistryProvider),
          agentName: pending.agentName,
          deviceAuthenticated: true,
          priorScan: pending.scan,
        );
        if (ctx.mounted) Navigator.pop(ctx);
        if (context.mounted) {
          if (ok) onPromoted?.call();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ok
                    ? '${pending.agentName} force-promoted to Mere Bhai.'
                    : 'Promotion failed.',
              ),
            ),
          );
        }
        return null;
      },
    ),
  );
}

/// Force-promote dialog that stays open on auth failure and shows an inline error.
class _ForcePromoteDialog extends StatefulWidget {
  final PendingPromotion pending;
  final VoidCallback onKeepAtC4;

  /// Returns an error message on failure, or null on success / dialog closed.
  final Future<String?> Function() onForcePromote;

  const _ForcePromoteDialog({
    required this.pending,
    required this.onKeepAtC4,
    required this.onForcePromote,
  });

  @override
  State<_ForcePromoteDialog> createState() => _ForcePromoteDialogState();
}

class _ForcePromoteDialogState extends State<_ForcePromoteDialog> {
  bool _busy = false;
  String? _inlineError;

  Future<void> _tryPromote() async {
    setState(() {
      _busy = true;
      _inlineError = null;
    });
    try {
      final err = await widget.onForcePromote();
      if (mounted && err != null) {
        setState(() => _inlineError = err);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Text(
        'Due Diligence Warning',
        style: TextStyle(color: Colors.amber),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${pending.agentName} was flagged:',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            DueDiligenceFindingsList(scan: pending.scan),
            const SizedBox(height: 12),
            const Text(
              'Proceed only if you trust this agent. Force-promotion requires your device screen lock or fingerprint.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (_inlineError != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A1515),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _inlineError!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : widget.onKeepAtC4,
          child: const Text('KEEP IN SABKE BHAI'),
        ),
        TextButton(
          onPressed: _busy ? null : _tryPromote,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text(
                  'AUTHENTICATE & PROMOTE',
                  style: TextStyle(color: Colors.redAccent),
                ),
        ),
      ],
    );
  }
}

class AmbientHubScreen extends ConsumerStatefulWidget {
  const AmbientHubScreen({super.key});
  @override
  ConsumerState<AmbientHubScreen> createState() => _AmbientHubScreenState();
}

class _AmbientHubScreenState extends ConsumerState<AmbientHubScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController(initialPage: 1);
  TelemetryCollector? _collector;
  HeadsetMediaKeys? _headsetKeys;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Request location + start real sensors after first frame (not cold boot).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _collector = ref.read(telemetryCollectorProvider);
      unawaited(_collector!.start());
      final wake = ref.read(wakeWordServiceProvider);
      final engine = ref.read(voiceHandshakeProvider);
      wake.onWakeDetected = () {
        unawaited(engine.onMicSingleTap());
      };
      engine.onLoudPlaybackStarting = () {
        final w = ref.read(wakeWordServiceProvider);
        return w.yieldMicForLoudPlayback();
      };
      void resumeWakeIfIdle() {
        final w = ref.read(wakeWordServiceProvider);
        final eng = ref.read(voiceHandshakeProvider);
        if (eng.state == VoiceState.idle &&
            w.isAlwaysOn &&
            w.listenEnabled &&
            w.privacyAcknowledged) {
          unawaited(w.startListening());
        }
      }
      engine.onReturnedToIdle = resumeWakeIfIdle;
      engine.onLoudPlaybackFinished = resumeWakeIfIdle;
      _ensureHeadsetKeys();
      _syncHeadsetCapture(
        ref.read(byokServiceProvider).mediaControlsToAurBhai,
      );
      final calls = ref.read(broCallServiceProvider);
      calls.onDeliverPayload = (call) {
        final eng = ref.read(voiceHandshakeProvider);
        unawaited(
          eng.speak(call.speakText.isEmpty ? call.body : call.speakText),
        );
      };
      calls.onCallQueued = (call) {
        final eng = ref.read(voiceHandshakeProvider);
        unawaited(eng.speak(AppConfig.broCallCuePhrase));
      };
      unawaited(ref.read(issueReportServiceProvider).load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _collector;
    if (c == null) return;
    final serverRunning = ref.read(localServerProvider).isRunning;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (!serverRunning) {
        unawaited(c.pause());
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(c.resume());
      c.resubscribeSensors();
      unawaited(ref.read(issueReportServiceProvider).refreshStatuses());
      final wake = ref.read(wakeWordServiceProvider);
      if (wake.isAlwaysOn && wake.listenEnabled) {
        unawaited(wake.startListening());
      }
    }
  }

  void _ensureHeadsetKeys() {
    if (_headsetKeys != null) return;
    final engine = ref.read(voiceHandshakeProvider);
    _headsetKeys = HeadsetMediaKeys(
      onShortPress: () => unawaited(engine.onMicSingleTap()),
      onLongPressStart: () => unawaited(engine.onMicHoldStart()),
      onLongPressEnd: () => unawaited(engine.onMicHoldEnd()),
      onCancel: () => unawaited(engine.onMicDoubleTap()),
    );
  }

  void _syncHeadsetCapture(bool enabled) {
    _ensureHeadsetKeys();
    if (enabled) {
      _headsetKeys!.attach();
    } else {
      _headsetKeys!.detach();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _headsetKeys?.detach();
    // Do not ref.read after unmount — widget_test dispose crash.
    unawaited(_collector?.stop() ?? Future<void>.value());
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      byokServiceProvider.select((b) => b.mediaControlsToAurBhai),
      (prev, next) {
        if (prev == next) return;
        _syncHeadsetCapture(next);
      },
    );
    return _PromotionDialogHost(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: PageView(
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          children: const [
            _SettingsPage(),
            _CommandCenterPage(),
            _PluginsPage(),
          ],
        ),
        bottomNavigationBar: BottomAppBar(
          color: const Color(0xFF111111),
          padding: EdgeInsets.zero,
          height: 50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white54),
                onPressed: () => _pageController.animateToPage(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.ease,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.mic, color: Colors.white54),
                onPressed: () => _pageController.animateToPage(
                  1,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.ease,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.extension, color: Colors.white54),
                onPressed: () => _pageController.animateToPage(
                  2,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.ease,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Listens for post-author/refine promotion prompts (MS-USER-ECOSYSTEM-ENG4).
class _PromotionDialogHost extends ConsumerStatefulWidget {
  final Widget child;
  const _PromotionDialogHost({required this.child});
  @override
  ConsumerState<_PromotionDialogHost> createState() =>
      _PromotionDialogHostState();
}

class _PromotionDialogHostState extends ConsumerState<_PromotionDialogHost> {
  int _lastHandledPromotionId = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<AgentVerificationService>(agentVerificationProvider, (
      prev,
      next,
    ) {
      final pending = next.pendingPromotion;
      if (pending == null) return;
      if (next.promotionRequestId == _lastHandledPromotionId) return;
      _lastHandledPromotionId = next.promotionRequestId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAgentPromotionDialog(context, ref, pending);
      });
    });
    return widget.child;
  }
}

class _CommandCenterPage extends ConsumerStatefulWidget {
  const _CommandCenterPage();
  @override
  ConsumerState<_CommandCenterPage> createState() => _CommandCenterPageState();
}

class _CommandCenterPageState extends ConsumerState<_CommandCenterPage>
    with TickerProviderStateMixin {
  late AnimationController _bCtrl;
  late Animation<double> _bOpacity;
  final _simulatorCtrl = TextEditingController();
  bool _simulatorBusy = false;

  @override
  void initState() {
    super.initState();
    _bCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _bOpacity = Tween<double>(
      begin: 0.1,
      end: 0.4,
    ).animate(CurvedAnimation(parent: _bCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _bCtrl.dispose();
    _simulatorCtrl.dispose();
    super.dispose();
  }

  /// Ultra-short bar label (device name lives in the tap explanation).
  String _wakeMicBarLabel(WakeWordService wake) {
    if (wake.isHandingOff || wake.inputRouteKind == 'handoff') return 'Cmd';
    if (!wake.isListening) return 'Off';
    switch (wake.inputRouteKind) {
      case 'bluetooth':
        return 'BT';
      case 'wired':
        return 'Wire';
      case 'phone':
        return 'Phone';
      default:
        return 'Mic';
    }
  }

  IconData _wakeMicIcon(WakeWordService wake) {
    if (wake.isHandingOff || wake.inputRouteKind == 'handoff') {
      return Icons.record_voice_over;
    }
    if (!wake.isListening) return Icons.mic_off;
    switch (wake.inputRouteKind) {
      case 'bluetooth':
        return Icons.bluetooth_audio;
      case 'wired':
        return Icons.headphones;
      case 'phone':
        return Icons.phone_android;
      default:
        return Icons.mic;
    }
  }

  String _wakeMatchBarLabel(WakeWordService wake) {
    // Activate outruns the live meter (logs: 2% → 100% hit → "Heard" in <400ms).
    if (wake.heardWakeRecently()) {
      final pct = wake.lastWakeMatchPercent;
      return pct > 0 ? 'Heard·$pct%' : 'Heard';
    }
    if (!wake.isListening) {
      return wake.isHandingOff ? 'Cmd' : '—';
    }
    final pct = (wake.liveMatch * 100).clamp(0, 100).round();
    // Second part is mic loudness (not match). mute/low/ok/loud.
    final lvl = switch (wake.levelCue) {
      'silent' => 'mute',
      'low' => 'low',
      'loud' => 'loud',
      _ => 'ok',
    };
    return '$pct%·$lvl';
  }

  String _wakeMicExplain(WakeWordService wake) {
    if (wake.isHandingOff) {
      return 'Wake mic paused so the command turn can use the mic.';
    }
    if (!wake.isListening) {
      return 'Wake listen is off. Set Listen to Always-on in Settings.';
    }
    return 'Wake is listening on ${wake.inputRouteLabel}.';
  }

  String _wakeMatchExplain(WakeWordService wake) {
    if (wake.heardWakeRecently()) {
      final pct = wake.lastWakeMatchPercent;
      return 'Heard “${wake.lastWakeLabel ?? wake.activePhraseLabel}”'
          '${pct > 0 ? ' at $pct%' : ''}. Say your command now.';
    }
    if (!wake.isListening) {
      return 'No live wake match while listen is off.';
    }
    final pct = (wake.liveMatch * 100).clamp(0, 100).round();
    final need = wake.matchThresholdPercent;
    final level = switch (wake.levelCue) {
      'silent' => 'no audio from this mic (buds may be silent / SCO idle)',
      'low' => 'quiet — speak closer or louder',
      'loud' => 'mic input is very loud (clipping risk)',
      _ => 'level looks ok',
    };
    return 'Wake match $pct% (trigger at ≥$need%) for “${wake.activePhraseLabel}”. '
        'Mic level: $level. Match jumps when the phrase completes — it is not a '
        'smooth 0→100 progress bar. Tiny 1% blips are noise. '
        'Change the trigger in Settings → Wake match threshold.';
  }

  void _showStatusExplain(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title\n$body'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _statusCue(
    BuildContext context, {
    required IconData icon,
    required Color color,
    String? label,
    required String title,
    required String explain,
  }) {
    return Tooltip(
      message: '$title — tap for details',
      child: InkWell(
        onTap: () => _showStatusExplain(context, title: title, body: explain),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 14),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runSimulator() async {
    var text = _simulatorCtrl.text.trim();
    if (text.isEmpty || _simulatorBusy) return;

    text = ref.read(defaultMereBhaiProvider).applyTextPrefix(text);

    setState(() => _simulatorBusy = true);
    try {
      await ref.read(voiceHandshakeProvider).processVoiceCommand(text);
      if (mounted) _simulatorCtrl.clear();
    } finally {
      if (mounted) setState(() => _simulatorBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eng = ref.watch(voiceHandshakeProvider);
    eng.onAutoLaunchDashboard ??= (url) {
      if (mounted) launchInBrowser(context, url);
    };
    final byok = ref.watch(byokServiceProvider);
    final server = ref.watch(localServerProvider);
    final session = ref.watch(conversationalSessionProvider);
    final wake = ref.watch(wakeWordServiceProvider);
    final defaultBhai = ref.watch(defaultMereBhaiProvider);

    return SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([eng, byok, server, wake, defaultBhai]),
        builder: (context, _) {
          final isListening =
              eng.state == VoiceState.listening ||
              eng.state == VoiceState.processing;
          final sessionLabel = session.isActive
              ? (session.kind == SessionKind.author
                    ? 'AUTHOR SESSION'
                    : 'REFINE SESSION')
              : null;
          final mereBhai = ref.watch(agentServiceProvider).agents.where((a) {
            if (a is! JsAgentAdapter) return true;
            return a.securityClass == AgentSecurityClass.c2Verified;
          }).toList();
          final defaultName = defaultBhai.name;
          final defaultValid =
              defaultName != null && mereBhai.any((a) => a.name == defaultName);
          final micColor = wake.isHandingOff
              ? Colors.amberAccent
              : wake.isListening
              ? (wake.inputRouteKind == 'bluetooth'
                    ? Colors.lightBlueAccent
                    : Colors.greenAccent)
              : Colors.grey;
          final matchColor = wake.heardWakeRecently()
              ? Colors.amberAccent
              : wake.isListening && wake.levelCue == 'silent'
              ? Colors.redAccent
              : wake.isListening && wake.liveMatch >= 0.45
              ? Colors.orangeAccent
              : wake.isListening && wake.levelCue == 'low'
              ? Colors.orangeAccent
              : wake.isListening
              ? Colors.white70
              : Colors.white38;
          return Column(
            children: [
              // Compact status cues — tap any chip for a plain-language explain.
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 2,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _statusCue(
                            context,
                            icon: _wakeMicIcon(wake),
                            color: micColor,
                            label: _wakeMicBarLabel(wake),
                            title: 'Wake mic',
                            explain: _wakeMicExplain(wake),
                          ),
                          _statusCue(
                            context,
                            icon: Icons.graphic_eq,
                            color: matchColor,
                            label: _wakeMatchBarLabel(wake),
                            title: 'Wake match',
                            explain: _wakeMatchExplain(wake),
                          ),
                          _statusCue(
                            context,
                            icon: Icons.record_voice_over_outlined,
                            color: wake.isListening
                                ? Colors.white54
                                : Colors.white24,
                            label: wake.activePhraseLabel,
                            title: 'Wake phrase',
                            explain:
                                'Say “${wake.activePhraseLabel}” to wake. '
                                'Change the model in Settings → Wake word library.',
                          ),
                        ],
                      ),
                    ),
                    _statusCue(
                      context,
                      icon: Icons.dashboard_outlined,
                      color: server.isRunning ? Colors.green : Colors.red,
                      label: null,
                      title: 'Dashboard',
                      explain: server.isRunning
                          ? 'Local vault dashboard server is on — open vault '
                              'pages from Settings / Plugins on this phone.'
                          : 'Dashboard server is off. Turn it on in Settings '
                              'when you want local vault pages.',
                    ),
                    _statusCue(
                      context,
                      icon: byok.hasApiKey
                          ? Icons.key
                          : Icons.key_off_outlined,
                      color: byok.hasApiKey ? Colors.green : Colors.amber,
                      label: byok.hasApiKey ? null : 'Key',
                      title: 'AI key',
                      explain: byok.hasApiKey
                          ? 'API key is saved for model calls.'
                          : 'No API key yet — add one in Settings to talk to the AI.',
                    ),
                  ],
                ),
              ),
              if (sessionLabel != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.amber,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        sessionLabel,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 10,
                          fontFamily: 'Courier',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (session.kind == SessionKind.author)
                        TextButton(
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              useSafeArea: true,
                              backgroundColor: const Color(0xFF141414),
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(16),
                                ),
                              ),
                              builder: (_) => const _AuthoringPanelSheet(),
                            );
                          },
                          child: const Text(
                            'OPEN AUTHORING',
                            style: TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      TextButton(
                        onPressed: () {
                          session.cancel();
                          eng.speak('Session cancelled.');
                        },
                        child: const Text(
                          'CANCEL',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                ),

              // Log Panel (Scrollable)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161616),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: eng.sessionLogs.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'Tap the mic to talk, or type below.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white30,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(12),
                          reverse:
                              true, // newest logs at bottom (wait, if we reverse, and list is inserted at 0, 0 is at bottom)
                          itemCount: eng.sessionLogs.length,
                          separatorBuilder: (c, i) =>
                              const Divider(color: Colors.white10, height: 16),
                          itemBuilder: (context, index) {
                            final log = eng.sessionLogs[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      log.title.toUpperCase(),
                                      style: TextStyle(
                                        color: log.isError
                                            ? Colors.redAccent
                                            : Colors.greenAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      DateFormat(
                                        'HH:mm:ss',
                                      ).format(log.timestamp),
                                      style: const TextStyle(
                                        color: Colors.white30,
                                        fontSize: 8,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  log.message,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontFamily: 'Courier',
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),

              // Central Tap Zone (Restricted area, subtle gradient)
              Padding(
                padding: const EdgeInsets.only(bottom: 40, top: 20),
                child: GestureDetector(
                  onTap: () => eng.onMicSingleTap(),
                  onDoubleTap: () => eng.onMicDoubleTap(),
                  onLongPressStart: (_) => eng.onMicHoldStart(),
                  onLongPressEnd: (_) => eng.onMicHoldEnd(),
                  child: AnimatedBuilder(
                    animation: _bOpacity,
                    builder: (c, _) => Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: isListening
                              ? [
                                  const Color(0xFF444444),
                                  const Color(0xFF222222),
                                ]
                              : [
                                  Colors.white.withValues(
                                    alpha: _bOpacity.value,
                                  ),
                                  Colors.transparent,
                                ],
                        ),
                        boxShadow: isListening
                            ? [
                                const BoxShadow(
                                  color: Colors.white24,
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                        border: Border.all(color: Colors.white10, width: 2),
                      ),
                      child: Center(
                        child: Icon(
                          isListening ? Icons.graphic_eq : Icons.mic_none,
                          color: isListening ? Colors.white : Colors.white30,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              Text(
                eng.micStatusMessage,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Text(
                      defaultValid ? 'Default:' : 'Bhai:',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1E1E1E),
                          value: defaultValid ? defaultName : null,
                          hint: const Text(
                            'Any / auto',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          icon: const Icon(
                            Icons.arrow_drop_down,
                            color: Colors.white38,
                            size: 20,
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text(
                                'Any / auto',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            ...mereBhai.map(
                              (a) => DropdownMenuItem<String?>(
                                value: a.name,
                                child: Text(
                                  a.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            unawaited(
                              ref.read(defaultMereBhaiProvider).setDefault(v),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _simulatorCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          hintText:
                              'Ask a Mere Bhai, build a Bhai, or type a command…',
                          hintStyle: TextStyle(
                            color: Colors.white24,
                            fontSize: 11,
                          ),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _runSimulator(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _simulatorBusy ? null : _runSimulator,
                      icon: _simulatorBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send, color: Colors.greenAccent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}

/// Free openWakeWord catalog: download / set active / delete dormant.
class _WakeModelLibraryPanel extends ConsumerWidget {
  const _WakeModelLibraryPanel({
    required this.activeId,
    required this.onActiveChanged,
  });

  final String activeId;
  final ValueChanged<String> onActiveChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wake = ref.watch(wakeWordServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Wake word library',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        ...WakeHandshakeConfig.wakeCatalog.map((spec) {
          return FutureBuilder<bool>(
            future: wake.library.isInstalled(spec.id),
            builder: (context, snap) {
              final installed = snap.data ?? spec.bundled;
              final isActive = activeId == spec.id;
              final downloading = wake.downloadingId == spec.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Say “${spec.label}”',
                            style: TextStyle(
                              color: isActive
                                  ? Colors.greenAccent
                                  : Colors.white,
                              fontSize: 13,
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            spec.bundled
                                ? 'Bundled · ${isActive ? "active phrase" : "installed"}'
                                : installed
                                ? (isActive
                                      ? 'Active phrase'
                                      : 'Installed (dormant)')
                                : 'Not installed — free download',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                          if (downloading)
                            LinearProgressIndicator(
                              value: wake.downloadProgress > 0
                                  ? wake.downloadProgress
                                  : null,
                              backgroundColor: Colors.white12,
                              color: Colors.greenAccent,
                            ),
                        ],
                      ),
                    ),
                    if (!installed && !spec.bundled)
                      TextButton(
                        onPressed: downloading
                            ? null
                            : () async {
                                try {
                                  await wake.downloadModel(spec.id);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '${spec.label} downloaded',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                }
                              },
                        child: const Text('Download'),
                      ),
                    if (installed) ...[
                      TextButton(
                        onPressed: isActive
                            ? null
                            : () async {
                                try {
                                  await wake.setActiveWakeModel(spec.id);
                                  onActiveChanged(spec.id);
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                }
                              },
                        child: Text(isActive ? 'Active' : 'Use'),
                      ),
                      if (!spec.bundled && !isActive)
                        IconButton(
                          tooltip: 'Delete to free space',
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.white38,
                            size: 20,
                          ),
                          onPressed: () async {
                            try {
                              await wake.deleteModel(spec.id);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('$e')),
                                );
                              }
                            }
                          },
                        ),
                    ],
                  ],
                ),
              );
            },
          );
        }),
      ],
    );
  }
}

class _SettingsPage extends ConsumerStatefulWidget {
  const _SettingsPage();
  @override
  ConsumerState<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<_SettingsPage> {
  final _keyCtrl = TextEditingController();
  final _modCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _respWordCtrl = TextEditingController(text: "Haan bhai");
  final _userHandleCtrl = TextEditingController(text: "@you");
  final _circleOwnerCtrl = TextEditingController();
  final _circleRepoCtrl = TextEditingController();
  final _circleTokenCtrl = TextEditingController();
  final _circleAuthorCtrl = TextEditingController();
  String _circleStatus = 'Loading circle settings…';
  bool _circleBusy = false;
  String _provider = "Google Gemini";
  String? _thinkingLevel;
  int? _maxOutputTokens;
  bool _obscure = true;
  String _gender = "Male";
  bool _isGeneratingTTS = false;

  final Map<String, TextEditingController> _externalKeyCtrls = {
    for (final p in ExternalPlatform.values) p.name: TextEditingController(),
  };

  double _maxRecSecs = 10;
  String _tapAck = WakeHandshakeConfig.tapSpoken;
  String _holdAck = WakeHandshakeConfig.holdHaptic;
  String _listenMode = WakeHandshakeConfig.listenOnDemand;
  String _wakeBuiltin = WakeHandshakeConfig.defaultWakeModelId;
  bool _vibrate = false;
  bool _mediaControlsToAurBhai = true;

  @override
  void initState() {
    super.initState();
    final byok = ref.read(byokServiceProvider);
    _keyCtrl.text = byok.apiKey;
    _modCtrl.text = byok.modelName;
    _urlCtrl.text = byok.customUrl;
    _provider = byok.apiProvider;
    _thinkingLevel = byok.thinkingLevel;
    _maxOutputTokens = byok.maxOutputTokens;
    _maxRecSecs = byok.maxRecordingSeconds.toDouble();
    _tapAck = byok.tapResponseMode;
    _holdAck = byok.holdResponseMode;
    _vibrate = byok.vibrateOnWake;
    _mediaControlsToAurBhai = byok.mediaControlsToAurBhai;
    final wake = ref.read(wakeWordServiceProvider);
    _listenMode = wake.listenMode;
    _wakeBuiltin = wake.builtinKeywordId;
    _respWordCtrl.text = byok.responseWord;
    _userHandleCtrl.text = byok.userHandle;
    _gender = byok.voiceGender;
    for (final platform in ExternalPlatform.values) {
      _externalKeyCtrls[platform.name]?.text = byok.externalKeyFor(platform);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final circle = ref.read(circleRegistryProvider);
      await circle.loadConfig();
      if (!mounted) return;
      _circleOwnerCtrl.text = circle.owner;
      _circleRepoCtrl.text = circle.repo;
      _circleAuthorCtrl.text = circle.authorDisplay;
      // Never put the PAT into the TextField (blank = keep stored token).
      _circleTokenCtrl.clear();
      setState(() {
        _circleStatus = circle.isConfigured
            ? 'Ready: ${circle.owner}/${circle.repo} · PAT on device'
            : circle.hasToken
            ? 'PAT on device — set GitHub owner/repo and SAVE'
            : 'Not configured — enter owner, repo, PAT, then SAVE';
      });
    });
    _modCtrl.addListener(_onModelOrUrlChanged);
    _urlCtrl.addListener(_onModelOrUrlChanged);
  }

  void _onModelOrUrlChanged() {
    if (!mounted) return;
    setState(() {
      _thinkingLevel = LlmCapabilityCatalog.clampThinking(
        _provider,
        _modCtrl.text.trim(),
        _thinkingLevel,
      );
    });
    _autoSaveLlmConfig();
  }

  void _autoSaveLlmConfig() {
    if (!mounted) return;
    ref.read(byokServiceProvider).updateConfig(
          provider: _provider,
          apiKey: _keyCtrl.text.trim(),
          modelName: _modCtrl.text.trim(),
          customUrl: _urlCtrl.text.trim(),
          thinkingLevel: _thinkingLevel,
          maxOutputTokens: _maxOutputTokens,
          maxRecordingSeconds: _maxRecSecs.toInt(),
          responseMode: _tapAck,
          tapResponseMode: _tapAck,
          holdResponseMode: _holdAck,
          vibrateOnWake: _vibrate,
          responseWord: _respWordCtrl.text.trim(),
          voiceGender: _gender,
          mediaControlsToAurBhai: _mediaControlsToAurBhai,
        );
  }

  @override
  void dispose() {
    _modCtrl.removeListener(_onModelOrUrlChanged);
    _urlCtrl.removeListener(_onModelOrUrlChanged);
    _keyCtrl.dispose();
    _modCtrl.dispose();
    _urlCtrl.dispose();
    _respWordCtrl.dispose();
    _userHandleCtrl.dispose();
    _circleOwnerCtrl.dispose();
    _circleRepoCtrl.dispose();
    _circleTokenCtrl.dispose();
    _circleAuthorCtrl.dispose();
    for (final c in _externalKeyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _selectedProviderSupportsTts {
    return LlmProviderFactory.forProviderId(
      _provider,
      const LlmProviderConfig(apiKey: '', model: ''),
    ).supportsTts;
  }

  void _generateLLMVoice() async {
    setState(() => _isGeneratingTTS = true);
    final success = await ref
        .read(llmServiceProvider)
        .generateAndSaveResponseAudio(
          _respWordCtrl.text.trim(),
          'en-IN',
          _gender,
        );
    setState(() => _isGeneratingTTS = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? "LLM Voice Generated & Saved!"
                : "LLM Voice Gen Failed (Check API Provider support)",
          ),
        ),
      );
    }
  }

  void _save() async {
    final wake = ref.read(wakeWordServiceProvider);
    // Persist wake first so credential/BYOK failures cannot leave listen unset.
    try {
      if (!wake.privacyAcknowledged &&
          _listenMode == WakeHandshakeConfig.listenAlwaysOn) {
        await wake.acknowledgePrivacy();
      }
      try {
        await wake.setActiveWakeModel(_wakeBuiltin);
      } catch (_) {
        // Active model may not be installed yet; listen mode still saves.
      }
      await wake.setListenMode(_listenMode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Wake save failed: $e')),
        );
      }
    }

    final externalKeys = <String, String>{};
    for (final platform in ExternalPlatform.values) {
      final value = _externalKeyCtrls[platform.name]?.text.trim() ?? '';
      if (value.isNotEmpty) externalKeys[platform.name] = value;
    }
    await ref.read(byokServiceProvider).updateUserHandle(_userHandleCtrl.text.trim());
    try {
      await ref
          .read(byokServiceProvider)
          .updateConfig(
            provider: _provider,
            apiKey: _keyCtrl.text.trim(),
            modelName: _modCtrl.text.trim(),
            customUrl: _urlCtrl.text.trim(),
            thinkingLevel: _thinkingLevel,
            maxOutputTokens: _maxOutputTokens,
            maxRecordingSeconds: _maxRecSecs.toInt(),
            responseMode: _tapAck,
            tapResponseMode: _tapAck,
            holdResponseMode: _holdAck,
            vibrateOnWake: _vibrate,
            responseWord: _respWordCtrl.text.trim(),
            voiceGender: _gender,
            mediaControlsToAurBhai: _mediaControlsToAurBhai,
            externalPlatformKeys: externalKeys,
          );
      await ref.read(voiceHandshakeProvider).setTtsGender(_gender);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Credentials save failed: $e')),
        );
      }
      return;
    }
    if (mounted) {
      final listening = wake.isListening;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            listening
                ? 'Saved — listening for “${wake.activePhraseLabel}”'
                : 'Saved — wake listen off (set Listen to Always-on)',
          ),
        ),
      );
    }
  }

  Widget _settingsSection({
    required String title,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        collapsedIconColor: Colors.white54,
        iconColor: Colors.greenAccent,
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "SOVEREIGN VAULT & SETTINGS",
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Open a section below. Vault dashboards and Model Studio live here so BHAI LOG stays for Bhai Codes.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const Divider(color: Colors.white12, height: 24),
            _settingsSection(
              title: 'VAULT DASHBOARDS',
              initiallyExpanded: true,
              children: const [_VaultDashboardsBanner(showTitle: false)],
            ),
            _settingsSection(
              title: 'API / LLM',
              initiallyExpanded: true,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _provider,
                  dropdownColor: const Color(0xFF1E1E1E),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: "API Provider",
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  items: LlmProviderFactory.providerIds
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _provider = val;
                        _modCtrl.text = LlmProviderFactory.defaultModelFor(val);
                        _thinkingLevel = LlmCapabilityCatalog.clampThinking(
                          val,
                          _modCtrl.text.trim(),
                          null,
                        );
                        _maxOutputTokens = LlmCapabilityCatalog.forModel(
                          val,
                          _modCtrl.text.trim(),
                        ).maxTokensDefault;
                      });
                      _autoSaveLlmConfig();
                    }
                  },
                ),
                LlmProviderCapabilityNotice(providerId: _provider),
                const SizedBox(height: 16),
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscure,
                  onSubmitted: (_) => _autoSaveLlmConfig(),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: "API Key",
                    helperText: LlmProviderFactory.apiKeyHint(_provider),
                    helperStyle: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                    labelStyle: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                        color: Colors.white30,
                        size: 16,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                LlmModelPicker(
                  providerId: _provider,
                  controller: _modCtrl,
                ),
                LlmCapabilityKnobs(
                  providerId: _provider,
                  modelId: _modCtrl.text.trim(),
                  apiKey: _keyCtrl.text.trim(),
                  thinkingLevel: _thinkingLevel,
                  maxOutputTokens: _maxOutputTokens,
                  onChanged: ({thinkingLevel, maxOutputTokens}) {
                    setState(() {
                      if (thinkingLevel != null) {
                        _thinkingLevel = thinkingLevel;
                      }
                      if (maxOutputTokens != null) {
                        _maxOutputTokens = maxOutputTokens;
                      }
                    });
                    _autoSaveLlmConfig();
                  },
                ),
                if (LlmProviderFactory.requiresCustomUrl(_provider)) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: "Endpoint URL",
                      labelStyle: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Per-function LLM slots',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: Text(
                    ref.watch(byokServiceProvider).multiSlotEnabled
                        ? 'On — language/author/improve/judge can use different APIs (empty slot → default)'
                        : 'Off — one provider for all functions',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  value: ref.watch(byokServiceProvider).multiSlotEnabled,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (v) async {
                    await ref.read(byokServiceProvider).setMultiSlotEnabled(v);
                    if (v) {
                      await ref
                          .read(byokServiceProvider)
                          .updateSlot(
                            LlmSlot.defaultSlot,
                            ByokSlotConfig(
                              provider: _provider,
                              apiKey: _keyCtrl.text.trim(),
                              modelName: _modCtrl.text.trim(),
                              customUrl: _urlCtrl.text.trim(),
                              thinkingLevel: _thinkingLevel,
                              maxOutputTokens: _maxOutputTokens,
                            ),
                          );
                    }
                    setState(() {});
                  },
                ),
                if (ref.watch(byokServiceProvider).multiSlotEnabled) ...[
                  const SizedBox(height: 8),
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.only(left: 12),
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Colors.greenAccent, width: 2),
                      ),
                    ),
                    child: const LlmSlotEditors(),
                  ),
                ],
              ],
            ),
            _settingsSection(
              title: 'LOCAL EDGE SERVER',
              children: const [_EdgeServerPanel(compactTitle: true)],
            ),
            _settingsSection(
              title: 'WAKE & HANDSHAKE',
              initiallyExpanded: true,
              children: [
                Text(
                  AppConfig.wakePrivacyBody,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _listenMode,
                  dropdownColor: const Color(0xFF1E1E1E),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Listen',
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: WakeHandshakeConfig.listenAlwaysOn,
                      child: Text('Always-on'),
                    ),
                    DropdownMenuItem(
                      value: WakeHandshakeConfig.listenOnDemand,
                      child: Text('On-demand (UI / headset)'),
                    ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _listenMode = v);
                    final wake = ref.read(wakeWordServiceProvider);
                    try {
                      if (v == WakeHandshakeConfig.listenAlwaysOn &&
                          !wake.privacyAcknowledged) {
                        await wake.acknowledgePrivacy();
                      }
                      await wake.setListenMode(v);
                      if (!mounted) return;
                      final msg = wake.isListening
                          ? 'Listening for “${wake.activePhraseLabel}”'
                          : v == WakeHandshakeConfig.listenAlwaysOn
                          ? (wake.lastError ??
                                'Always-on saved but mic not listening yet')
                          : 'Wake listen off';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(msg)),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Wake listen failed: $e')),
                      );
                    }
                  },
                ),
                Builder(
                  builder: (context) {
                    final wake = ref.watch(wakeWordServiceProvider);
                    final phrase = wake.activePhraseLabel;
                    final pct = (wake.liveMatch * 100).clamp(0, 100).round();
                    final need = wake.matchThresholdPercent;
                    final lvl = wake.levelCue == 'loud'
                        ? 'loud'
                        : wake.levelCue;
                    final hitPct = wake.lastWakeMatchPercent;
                    final line = wake.isListening
                        ? 'Listening (${wake.inputRouteShort}) — “$phrase” · $pct% (need ≥$need%) · mic $lvl'
                        : wake.heardWakeRecently()
                        ? 'Wake heard at $hitPct% — mic freed for your command'
                        : wake.isHandingOff
                        ? 'Wake heard — mic freed for your command'
                        : 'Not listening. Phrase when on: “$phrase”';
                    return Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        line,
                        style: TextStyle(
                          color: wake.isListening
                              ? (wake.inputRouteKind == 'bluetooth'
                                    ? Colors.lightBlueAccent
                                    : Colors.greenAccent)
                              : Colors.amberAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    );
                  },
                ),
                Builder(
                  builder: (context) {
                    final wake = ref.watch(wakeWordServiceProvider);
                    final pct = wake.matchThresholdPercent.toDouble();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Wake match threshold: ${pct.round()}%',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        Slider(
                          value: pct,
                          min: 35,
                          max: 90,
                          divisions: 11,
                          activeColor: Colors.greenAccent,
                          label: '${pct.round()}%',
                          onChanged: (v) {
                            unawaited(wake.setMatchThreshold(v / 100));
                          },
                        ),
                        const Text(
                          'Lower = easier wake (more false triggers). '
                          'Match % is not 100% — a flash of 96% can miss if the mic was mute.',
                          style: TextStyle(color: Colors.white30, fontSize: 10),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  AppConfig.wakeCustomPpnHint,
                  style: const TextStyle(color: Colors.white30, fontSize: 10),
                ),
                const SizedBox(height: 4),
                Text(
                  AppConfig.wakeModelLibraryHint,
                  style: const TextStyle(color: Colors.white24, fontSize: 10),
                ),
                const SizedBox(height: 8),
                _WakeModelLibraryPanel(
                  activeId: _wakeBuiltin,
                  onActiveChanged: (id) => setState(() => _wakeBuiltin = id),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _tapAck,
                        dropdownColor: const Color(0xFF1E1E1E),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'Tap ack',
                          labelStyle: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        items: WakeHandshakeConfig.tapAckModes
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(
                                  m == WakeHandshakeConfig.tapSpoken
                                      ? 'Spoken'
                                      : m == WakeHandshakeConfig.tapSound
                                      ? 'Sound'
                                      : 'Silent',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _tapAck = v);
                            _autoSaveLlmConfig();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _holdAck,
                        dropdownColor: const Color(0xFF1E1E1E),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'Hold ack',
                          labelStyle: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        items: WakeHandshakeConfig.holdAckModes
                            .map(
                              (m) => DropdownMenuItem(value: m, child: Text(m)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _holdAck = v);
                            _autoSaveLlmConfig();
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (_tapAck == WakeHandshakeConfig.tapSpoken) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _respWordCtrl,
                    onSubmitted: (_) => _autoSaveLlmConfig(),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: 'Response word',
                      labelStyle: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    AppConfig.mediaControlsToggleLabel,
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: const Text(
                    AppConfig.mediaControlsToggleSubtitle,
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  value: _mediaControlsToAurBhai,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (v) async {
                    setState(() => _mediaControlsToAurBhai = v);
                    await ref
                        .read(byokServiceProvider)
                        .setMediaControlsToAurBhai(v);
                  },
                ),
                Text(
                  AppConfig.headsetRidingHint,
                  style: const TextStyle(color: Colors.white24, fontSize: 10),
                ),
                Builder(
                  builder: (context) {
                    final wake = ref.watch(wakeWordServiceProvider);
                    final status = wake.isListening
                        ? 'Mic armed — say “${wake.activePhraseLabel}”'
                        : wake.isAlwaysOn && wake.listenEnabled
                        ? 'Always-on set but mic stopped${wake.lastError != null ? ": ${wake.lastError}" : ""}'
                        : 'Wake listen off (openWakeWord idle)';
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        status,
                        style: TextStyle(
                          color: wake.isListening
                              ? Colors.greenAccent
                              : Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    );
                  },
                ),
                Builder(
                  builder: (context) {
                    final wake = ref.watch(wakeWordServiceProvider);
                    if (wake.lastError == null) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      wake.lastError!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ],
            ),
            _settingsSection(
              title: 'VOICE & AUDIO CONTROLS',
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _gender,
                  dropdownColor: const Color(0xFF1E1E1E),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: "Voice Gender",
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  items: const ["Male", "Female"]
                      .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _gender = val);
                      _autoSaveLlmConfig();
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      "Max Recording Duration:",
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: _maxRecSecs,
                        min: 7,
                        max: 15,
                        divisions: 8,
                        label: "${_maxRecSecs.toInt()}s",
                        activeColor: Colors.greenAccent,
                        onChanged: (val) {
                          setState(() => _maxRecSecs = val);
                          _autoSaveLlmConfig();
                        },
                      ),
                    ),
                    Text(
                      "${_maxRecSecs.toInt()}s",
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  title: const Text(
                    "Vibrate on tap wake",
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: Colors.greenAccent,
                  value: _vibrate,
                  onChanged: (val) {
                    setState(() => _vibrate = val);
                    _autoSaveLlmConfig();
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'Language: English only (Arch v3.7). Ambient commands and authoring replies are generated in English.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (!_selectedProviderSupportsTts)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'LLM voice synthesis requires OpenAI or Custom OpenAI (TTS not supported by this provider).',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF222222),
                    foregroundColor: Colors.greenAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: (_isGeneratingTTS || !_selectedProviderSupportsTts)
                      ? null
                      : _generateLLMVoice,
                  icon: _isGeneratingTTS
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(
                    _isGeneratingTTS
                        ? "GENERATING..."
                        : "GENERATE CUSTOM VOICE VIA LLM",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            _settingsSection(
              title: 'APP THEME & ACCENT GLOW',
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    final themeService = ref.watch(themeServiceProvider);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Base Palette',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: AppThemePalette.values.map((p) {
                            final isSel = themeService.currentPalette == p;
                            return ChoiceChip(
                              label: Text(p.label),
                              selected: isSel,
                              selectedColor: themeService.accentColor
                                  .withValues(alpha: 0.2),
                              backgroundColor: const Color(0xFF1E1E1E),
                              labelStyle: TextStyle(
                                color: isSel
                                    ? themeService.accentColor
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: isSel
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              side: BorderSide(
                                color: isSel
                                    ? themeService.accentColor
                                    : Colors.white12,
                              ),
                              onSelected: (_) => themeService.setPalette(p),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Accent Glow',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          children: AppAccentGlow.values.map((a) {
                            final isSel = themeService.currentAccent == a;
                            return GestureDetector(
                              onTap: () => themeService.setAccent(a),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSel ? a.color : Colors.white12,
                                    width: isSel ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: a.color,
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: a.color.withValues(
                                              alpha: 0.6,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      a.label,
                                      style: TextStyle(
                                        color: isSel
                                            ? Colors.white
                                            : Colors.white60,
                                        fontSize: 11,
                                        fontWeight: isSel
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
            _settingsSection(
              title: 'CLOSED CIRCLE (GITHUB REGISTRY)',
              children: [
                Text(
                  AppConfig.circlePublishConfirm,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Text(
                  AppConfig.circleFriendApkHint,
                  style: const TextStyle(color: Colors.white30, fontSize: 10),
                ),
                TextField(
                  controller: _circleOwnerCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'GitHub owner (optional)',
                    hintText:
                        'Defaults to PAT account; set if repo is under an org',
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                    hintStyle: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
                TextField(
                  controller: _circleRepoCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    labelText:
                        'Repo (optional, default ${AppConfig.circleDefaultRepo})',
                    labelStyle: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextField(
                  controller: _circleTokenCtrl,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Fine-grained PAT (contents + issues)',
                    hintText: 'Leave blank to keep the stored PAT',
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                    hintStyle: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
                TextField(
                  controller: _circleAuthorCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Display name on publishes (optional)',
                    hintText: 'Defaults to circle-user',
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                    hintStyle: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _circleStatus,
                  style: TextStyle(
                    color:
                        _circleStatus.startsWith('Connected') ||
                            _circleStatus.startsWith('Verified') ||
                            _circleStatus.startsWith('Ready')
                        ? Colors.tealAccent
                        : _circleStatus.startsWith('Failed')
                        ? Colors.redAccent
                        : Colors.white54,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _circleBusy
                          ? null
                          : () async {
                              setState(() => _circleBusy = true);
                              try {
                                final circle = ref.read(circleRegistryProvider);
                                await circle.saveConfig(
                                  owner: _circleOwnerCtrl.text,
                                  repo: _circleRepoCtrl.text,
                                  token: _circleTokenCtrl.text,
                                  authorDisplay: _circleAuthorCtrl.text,
                                );
                                _circleTokenCtrl.clear();
                                _circleOwnerCtrl.text = circle.owner;
                                _circleRepoCtrl.text = circle.repo;
                                final verified = await circle
                                    .verifyConnection();
                                if (!mounted) return;
                                setState(() {
                                  _circleStatus = 'Connected: $verified';
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Circle connected — $verified',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                setState(() => _circleStatus = 'Failed: $e');
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Circle save/verify failed: $e',
                                    ),
                                    backgroundColor: Colors.red.shade800,
                                  ),
                                );
                              } finally {
                                if (mounted)
                                  setState(() => _circleBusy = false);
                              }
                            },
                      child: Text(_circleBusy ? 'SAVING…' : 'SAVE & VERIFY'),
                    ),
                    TextButton(
                      onPressed: _circleBusy
                          ? null
                          : () async {
                              setState(() => _circleBusy = true);
                              try {
                                final verified = await ref
                                    .read(circleRegistryProvider)
                                    .verifyConnection();
                                if (!mounted) return;
                                setState(
                                  () => _circleStatus = 'Connected: $verified',
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Circle OK — $verified'),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                setState(() => _circleStatus = 'Failed: $e');
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Circle test failed: $e'),
                                    backgroundColor: Colors.red.shade800,
                                  ),
                                );
                              } finally {
                                if (mounted)
                                  setState(() => _circleBusy = false);
                              }
                            },
                      child: const Text('TEST CONNECTION'),
                    ),
                    TextButton(
                      onPressed: _circleBusy
                          ? null
                          : () async {
                              await ref
                                  .read(circleRegistryProvider)
                                  .clearToken();
                              if (!mounted) return;
                              _circleTokenCtrl.clear();
                              setState(() {
                                _circleStatus =
                                    'PAT cleared — paste a new PAT and SAVE & VERIFY';
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Circle PAT cleared'),
                                ),
                              );
                            },
                      child: const Text('CLEAR PAT'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await ref
                        .read(issueReportServiceProvider)
                        .refreshStatuses();
                    if (!mounted) return;
                    final reports = ref
                        .read(issueReportServiceProvider)
                        .reports;
                    await showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: const Color(0xFF1A1A1A),
                      builder: (ctx) => Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              AppConfig.issueMyReportsTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (reports.isEmpty)
                              const Text(
                                'No reports yet.',
                                style: TextStyle(color: Colors.white54),
                              )
                            else
                              ...reports
                                  .take(8)
                                  .map(
                                    (r) => Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        '#${r.githubIssueNumber ?? "-"} ${r.title}\n'
                                        '${r.status.name}'
                                        '${r.agentName != null ? " · ${r.agentName}" : ""}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: const Text('MY ISSUE REPORTS'),
                ),
              ],
            ),
            _settingsSection(
              title: 'SOVEREIGN IDENTITY & HANDLE',
              children: [
                const Text(
                  'Your sovereign author handle stamped on newly created or remixed Bhai Codes (e.g. @ishan, @you, @dev).',
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _userHandleCtrl,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Author Handle',
                    hintText: '@you or @yourname',
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                    hintStyle: TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                  onChanged: (val) {
                    ref.read(byokServiceProvider).updateUserHandle(val);
                  },
                ),
              ],
            ),
            _settingsSection(
              title: 'VAULT SECURITY & CLEANSE',
              children: [
                const Text(
                  'Promoting unverified/sandbox agents into Mere Bhai uses your on-device screen lock, biometric fingerprint, or PIN. Your sovereign vault is encrypted locally on this device.',
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.amberAccent,
                    side: BorderSide(color: Colors.amberAccent.withValues(alpha: 0.5)),
                  ),
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('RESET / CLEANSE SANDBOX & VAULT'),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF1E222D),
                        title: const Text('Cleanse Legacy Vault & Sandbox?'),
                        content: const Text(
                          'This will remove deprecated historical demo agents and unpicked sandbox seeds, resetting Mere Bhai to the Core Calculator and restoring all seed listings in Sabke Bhai for fresh browsing.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('CANCEL'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: Colors.amberAccent),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('RESET TO PRISTINE'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && context.mounted) {
                      final jsRegistry = ref.read(jsAgentRegistryProvider);
                      await jsRegistry.resetVaultToPristineCatalog();
                      await jsRegistry.loadAndRegisterAgents();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Vault and Sandbox cleansed to pristine state!'),
                            backgroundColor: Color(0xFF10B981),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EdgeServerPanel extends ConsumerWidget {
  const _EdgeServerPanel({this.compactTitle = false});

  /// When true, omit the large LOCAL EDGE SERVER heading (Settings ExpansionTile supplies it).
  final bool compactTitle;

  Future<void> _copyToClipboard(
    BuildContext context,
    String text,
    String label,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label copied')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(localServerProvider);

    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final statusColor = server.isRunning
            ? Colors.greenAccent
            : Colors.redAccent;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compactTitle) ...[
              const Text(
                'LOCAL EDGE SERVER',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),
            ],
            _edgeInfoRow('Status', server.statusLabel, valueColor: statusColor),
            _edgeInfoRow('Host', server.host),
            _edgeInfoRow(
              'Port',
              server.isRunning
                  ? '${server.port}'
                  : '${LocalServerService.defaultPort} (not bound)',
            ),
            _edgeInfoRow(
              'On device',
              server.isRunning ? server.localhostAddress : 'Offline',
            ),
            if (server.isRunning && server.lanIp != null)
              _edgeInfoRow(
                'LAN (Wi-Fi)',
                server.lanServerAddress,
                valueColor: Colors.greenAccent,
              ),
            if (server.isRunning && server.lanIp == null)
              _edgeInfoRow(
                'LAN (Wi-Fi)',
                'Unavailable — use on-device localhost',
                valueColor: Colors.amber,
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Allow LAN access',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: Text(
                server.lanExposureEnabled
                    ? 'Peers need pair code ${server.pairingToken}'
                    : 'Off — only localhost (this phone) can query/vault',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              value: server.lanExposureEnabled,
              activeThumbColor: Colors.greenAccent,
              onChanged: (v) => server.setLanExposureEnabled(v),
            ),
            if (server.lanExposureEnabled) ...[
              _edgeInfoRow(
                'Pair code',
                server.pairingToken,
                valueColor: Colors.amber,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    server.rotatePairingToken();
                    _copyToClipboard(context, server.pairingToken, 'Pair code');
                  },
                  icon: const Icon(
                    Icons.refresh,
                    size: 16,
                    color: Colors.white70,
                  ),
                  label: const Text(
                    'ROTATE / COPY PAIR',
                    style: TextStyle(fontSize: 10, color: Colors.white70),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'DEVELOPER MODE (MCP BRIDGE)',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Connect Antigravity, Cursor, or Claude Desktop to this phone to author Bhai Code over Wi-Fi.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      'python tool/mcp_proxy.py --url ${server.lanServerAddress}/api/mcp --token ${server.pairingToken}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            ListenableBuilder(
              listenable: ref.watch(telemetryCollectorProvider),
              builder: (context, _) {
                final c = ref.read(telemetryCollectorProvider);
                final last = c.lastSuccessAt;
                final lastLabel = last == null
                    ? 'never'
                    : DateFormat('HH:mm:ss').format(last);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    const Text(
                      'LIVE TELEMETRY',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _edgeInfoRow('Collector', c.status.name),
                    _edgeInfoRow('Last fix', lastLabel),
                    if (c.currentBackoff > Duration.zero)
                      _edgeInfoRow(
                        'Backoff',
                        '${c.currentBackoff.inSeconds}s',
                        valueColor: Colors.amber,
                      ),
                    if (c.lastError != null)
                      _edgeInfoRow(
                        'Error',
                        c.lastError!,
                        valueColor: Colors.redAccent,
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Registered endpoints',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 4),
            ...LocalServerService.coreEndpoints.map(
              (ep) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  ep,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'Courier',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    onPressed: server.isRunning
                        ? () => _copyToClipboard(
                            context,
                            server.statusUrl,
                            'Status URL',
                          )
                        : null,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text(
                      'COPY STATUS URL',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.greenAccent,
                      side: const BorderSide(color: Colors.greenAccent),
                    ),
                    onPressed: server.isRunning
                        ? () => launchInBrowser(context, server.statusUrl)
                        : null,
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text(
                      'OPEN STATUS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _edgeInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 12,
                fontFamily: 'Courier',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceTrainingStudio extends StatefulWidget {
  const _VoiceTrainingStudio();
  @override
  State<_VoiceTrainingStudio> createState() => _VoiceTrainingStudioState();
}

class _VoiceTrainingStudioState extends State<_VoiceTrainingStudio> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecordingResponse = false;
  bool _isRecordingWakeWord = false;
  int _wakeWordCount = 0;
  String _status = "";

  @override
  void initState() {
    super.initState();
    _checkCounts();
  }

  void _checkCounts() async {
    final dir = await getApplicationDocumentsDirectory();
    int count = 0;
    while (await File('${dir.path}/wakeword_sample_$count.m4a').exists()) {
      count++;
    }
    if (mounted) setState(() => _wakeWordCount = count);
  }

  void _toggleResponse() async {
    if (_isRecordingResponse) {
      await _recorder.stop();
      setState(() {
        _isRecordingResponse = false;
        _status = "Custom response saved!";
      });
    } else {
      if (await _recorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
          path: '${dir.path}/custom_response.m4a',
        );
        setState(() {
          _isRecordingResponse = true;
          _status = "Recording response... (Tap to stop)";
        });
      }
    }
  }

  void _toggleWakeWord() async {
    if (_isRecordingWakeWord) {
      await _recorder.stop();
      setState(() {
        _isRecordingWakeWord = false;
        _status = "Wake word sample saved!";
        _wakeWordCount++;
      });
    } else {
      if (await _recorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
          path: '${dir.path}/wakeword_sample_$_wakeWordCount.m4a',
        );
        setState(() {
          _isRecordingWakeWord = true;
          _status = "Recording wake word... (Tap to stop)";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "VOICE TRAINING STUDIO",
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          "Record your custom response (e.g. 'Haan Bhai') and collect wake word samples to build an offline model later.",
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 16),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _status,
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRecordingResponse
                      ? Colors.red
                      : const Color(0xFF333333),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _toggleResponse,
                icon: Icon(
                  _isRecordingResponse ? Icons.stop : Icons.mic,
                  size: 18,
                ),
                label: const Text(
                  "CUSTOM RESPONSE",
                  style: TextStyle(fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRecordingWakeWord
                      ? Colors.red
                      : const Color(0xFF333333),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _toggleWakeWord,
                icon: Icon(
                  _isRecordingWakeWord ? Icons.stop : Icons.mic,
                  size: 18,
                ),
                label: Text(
                  "WAKE WORD LOG ($_wakeWordCount)",
                  style: const TextStyle(fontSize: 10),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PluginsPage extends ConsumerWidget {
  const _PluginsPage();

  AgentSecurityClass _classOf(AurBhaiAgent a) =>
      a is JsAgentAdapter ? a.securityClass : AgentSecurityClass.c2Verified;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentServiceProvider).agents;

    final Map<AgentSecurityClass, List<AurBhaiAgent>> grouped = {
      for (final c in AgentSecurityClass.values) c: <AurBhaiAgent>[],
    };
    for (final a in agents) {
      grouped[_classOf(a)]!.add(a);
    }

    final wake = ref.watch(wakeWordServiceProvider);
    // Sandbox = unverified installs (C4/C3); Sabke = browse only.
    final sandboxInstalled = [
      ...grouped[AgentSecurityClass.c4Unverified]!,
      ...grouped[AgentSecurityClass.c3DueDiligence]!,
    ];
    return DefaultTabController(
      length: 4,
      initialIndex: 0, // Mere Bhai
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "BHAI LOG",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onPressed: () => _openAuthoringSheet(context, ref),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text(
                      "CREATE BHAI CODE",
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (wake.isListening)
              Container(
                width: double.infinity,
                color: const Color(0xFF10261A),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  AppConfig.wakeListeningIndicator,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 11,
                  ),
                ),
              ),
            TabBar(
              isScrollable: true,
              indicatorColor: Colors.greenAccent,
              labelColor: Colors.greenAccent,
              unselectedLabelColor: Colors.white54,
              tabs: [
                const Tab(text: "MERE BHAI"),
                const Tab(text: "SABKE BHAI"),
                const Tab(text: "SANDBOX"),
                Tab(text: AppConfig.circleTabLabel),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildAgentGrid(
                    context,
                    ref,
                    [
                      ...grouped[AgentSecurityClass.c1Core]!,
                      ...grouped[AgentSecurityClass.c2Verified]!,
                    ],
                    showOrigin: true,
                  ),
                  _buildSabkeBrowseGrid(context, ref, agents),
                  SandboxQueueTab(onOpenInstalled: _openAgentDetail),
                  const CircleMarketplaceTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Sabke Bhai: ecosystem seed catalog showing all curated listings and their on-device status.
  Widget _buildSabkeBrowseGrid(
    BuildContext context,
    WidgetRef ref,
    List<AurBhaiAgent> allInstalled,
  ) {
    final catalog = ref.watch(marketplaceCatalogProvider);
    final listings = catalog.listings();
    final installedMap = {for (final a in allInstalled) a.name: a};

    if (listings.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No seed listings available.\nFriend Circle has shared Bhai Codes from friends.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 13),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.92,
      ),
      itemCount: listings.length,
      itemBuilder: (context, index) {
        final listing = listings[index];
        final installedAgent = installedMap[listing.name];

        final bool inMereBhai = installedAgent is JsAgentAdapter &&
            (installedAgent.securityClass == AgentSecurityClass.c1Core ||
                installedAgent.securityClass == AgentSecurityClass.c2Verified);
        final bool inSandbox = installedAgent is JsAgentAdapter &&
            (installedAgent.securityClass == AgentSecurityClass.c4Unverified ||
                installedAgent.securityClass == AgentSecurityClass.c3DueDiligence);

        final Color borderColor = inMereBhai
            ? Colors.greenAccent.withValues(alpha: 0.45)
            : (inSandbox
                ? Colors.amberAccent.withValues(alpha: 0.45)
                : Colors.lightBlueAccent.withValues(alpha: 0.45));

        final Color iconColor = inMereBhai
            ? Colors.greenAccent
            : (inSandbox ? Colors.amberAccent : Colors.lightBlueAccent);

        final IconData icon = inMereBhai
            ? Icons.verified_outlined
            : (inSandbox ? Icons.shield_outlined : Icons.public);

        final String statusLabel = inMereBhai
            ? 'In Mere Bhai'
            : (inSandbox ? 'In Sandbox' : 'Browse · Get');

        return GestureDetector(
          onTap: () {
            if (installedAgent != null) {
              _openAgentDetail(context, ref, installedAgent);
            } else {
              BhaiCodePreviewSheet.open(context, listing: listing);
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: iconColor, size: 26),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    listing.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${listing.displayHandle} · $statusLabel',
                  style: TextStyle(
                    color: iconColor,
                    fontSize: 7,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAgentGrid(
    BuildContext context,
    WidgetRef ref,
    List<AurBhaiAgent> agents, {
    bool showOrigin = false,
  }) {
    if (agents.isEmpty) {
      return const Center(
        child: Text(
          "No Bhai Codes in this pool.",
          style: TextStyle(color: Colors.white30),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.0,
      ),
      itemCount: agents.length,
      itemBuilder: (context, index) {
        final a = agents[index];
        final js = a is JsAgentAdapter ? a : null;
        final builtAt = js != null ? (js.updatedAt ?? js.createdAt) : null;
        final diligenceChip = js?.securityClass.diligenceChip;
        final originLabel = showOrigin && js != null
            ? BhaiCodeOrigin.label(js.source)
            : null;
        return GestureDetector(
          onTap: () => _openAgentDetail(context, ref, a),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: diligenceChip != null
                    ? Colors.amber.withValues(alpha: 0.5)
                    : Colors.white10,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  showOrigin && js != null
                      ? _bhaiOriginIcon(js.source)
                      : (js != null ? Icons.javascript : Icons.extension),
                  color: js != null ? Colors.amberAccent : Colors.greenAccent,
                  size: 28,
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    a.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Builder(
                  builder: (context) {
                    final myHandle = ref.watch(byokServiceProvider).userHandle;
                    final handleText = js?.displayHandle(defaultUserHandle: myHandle);
                    final subtitle = handleText != null
                        ? (js!.remixCount > 0
                            ? '$handleText · ${js.remixCount} remix${js.remixCount > 1 ? "es" : ""}'
                            : handleText)
                        : (originLabel ?? 'built-in');
                    return Padding(
                      padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          color: js?.source == BhaiCodeOrigin.pool
                              ? Colors.cyanAccent
                              : (js?.source == BhaiCodeOrigin.self
                                  ? Colors.greenAccent
                                  : (js != null ? Colors.purpleAccent : Colors.white54)),
                          fontSize: 7,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openAuthoringSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _AgentAuthoringSheet(),
    );
  }

  void _openAgentDetail(
    BuildContext context,
    WidgetRef ref,
    AurBhaiAgent agent,
  ) {
    final fromSandbox =
        agent is JsAgentAdapter &&
        (agent.securityClass == AgentSecurityClass.c4Unverified ||
            agent.securityClass == AgentSecurityClass.c3DueDiligence);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _AgentDetailSheet(agent: agent, fromSandbox: fromSandbox),
    );
  }
}

/// Surfaces user-created HTML dashboards stored in the sovereign vault
/// (MS-TELEMETRY-DASHBOARD-UX1). Compact rows + kebab; TTL renew/extend (UX3).
class _VaultDashboardsBanner extends ConsumerStatefulWidget {
  const _VaultDashboardsBanner({this.showTitle = true});

  final bool showTitle;

  @override
  ConsumerState<_VaultDashboardsBanner> createState() =>
      _VaultDashboardsBannerState();
}

class _VaultDashboardsBannerState
    extends ConsumerState<_VaultDashboardsBanner> {
  late Future<List<Map<String, String>>> _future;
  int _lastTick = 0;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, String>>> _load() async {
    final list = await ref
        .read(telemetryBusProvider)
        .listVaultEntries(mimeType: 'text/html');
    final filtered = <Map<String, String>>[];
    final seen = <String>{};
    for (final e in list) {
      final key = e['key'] ?? '';
      // Skip internal scoped asset keys (e.g. agent:Accountant:asset:...)
      if (key.startsWith('agent:') && key.contains(':asset:')) continue;
      if (seen.add(key)) {
        filtered.add(e);
      }
    }
    return filtered;
  }

  void _refresh() => setState(() => _future = _load());

  String _ttlLabel(String expiresAt) {
    if (expiresAt.isEmpty) return 'forever';
    final at = DateTime.tryParse(expiresAt)?.toLocal();
    if (at == null) return 'forever';
    final left = at.difference(DateTime.now());
    if (left.isNegative) return 'expired';
    if (left.inHours < 48) return '~${left.inHours}h left';
    return '~${left.inDays}d left';
  }

  /// On phone, localhost reaches this device's edge server; LAN is for peers.
  String? _openUrl(LocalServerService server, String key) {
    if (!server.isRunning) return null;
    final k = normalizeVaultKeyForUrl(key);
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return '${server.localhostAddress}/vault/$k';
    }
    return server.vaultUrl(k);
  }

  String? _copyUrl(LocalServerService server, String key) {
    if (!server.isRunning) return null;
    return server.vaultUrl(key);
  }

  Future<void> _openDashboard(LocalServerService server, String key) async {
    final url = _openUrl(server, key);
    if (url == null) return;
    await launchVaultDashboard(context, url);
  }

  Future<void> _copyLink(LocalServerService server, String key) async {
    final url = _copyUrl(server, key);
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Dashboard URL copied')));
  }

  Future<void> _locateBroCode(String key) async {
    final agents = ref.read(agentServiceProvider).agents;
    final match = findAgentForDashboardKey(agents, key);
    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No Bhai Code matched "$key" (may be orphaned).'),
        ),
      );
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _AgentDetailSheet(agent: match),
    );
  }

  Future<void> _stopRemove(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Stop dashboard?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Remove "$key" from the vault? /vault/$key will stop serving.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'STOP / REMOVE',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(telemetryBusProvider).deleteVaultData(key);
    ref.read(vaultDashboardRefreshProvider).bump();
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Removed $key')));
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(localServerProvider);
    final refresh = ref.watch(vaultDashboardRefreshProvider);
    if (refresh.tick != _lastTick) {
      _lastTick = refresh.tick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }

    return FutureBuilder<List<Map<String, String>>>(
      future: _future,
      builder: (context, snapshot) {
        final dashboards = snapshot.data ?? const [];
        return Container(
          margin: const EdgeInsets.fromLTRB(0, 2, 0, 6),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (widget.showTitle)
                    const Expanded(
                      child: Text(
                        'VAULT DASHBOARDS',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: const Icon(
                      Icons.refresh,
                      color: Colors.white38,
                      size: 16,
                    ),
                    onPressed: _refresh,
                  ),
                ],
              ),
              if (dashboards.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 2, bottom: 2),
                  child: Text(
                    'No dashboards yet. Create an agent that builds one, then run it.',
                    style: TextStyle(
                      color: Colors.white30,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              else
                SizedBox(
                  height: (dashboards.length * 52.0).clamp(52.0, 240.0),
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      itemCount: dashboards.length,
                      itemBuilder: (context, index) {
                      final d = dashboards[index];
                      final key = d['key']!;
                      final buildId = d['build_id'];
                      final createdAt =
                          d['created_at'] ?? d['updated_at'] ?? '';
                      final expiresAt = d['expires_at'] ?? '';
                      final canOpen = server.isRunning;
                      final ttlLabel = _ttlLabel(expiresAt);
                      final agents = ref.read(agentServiceProvider).agents;
                      final associated =
                          findAgentForDashboardKey(agents, key)?.name ?? '—';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    key,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'TTL $ttlLabel · $associated',
                                    style: const TextStyle(
                                      color: Color(0xFFB8F5C0),
                                      fontSize: 8,
                                      fontFamily: 'Courier',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'Open',
                              icon: Icon(
                                Icons.open_in_browser,
                                color: canOpen
                                    ? Colors.greenAccent
                                    : Colors.white24,
                                size: 18,
                              ),
                              onPressed: canOpen
                                  ? () => _openDashboard(server, key)
                                  : null,
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'Share link to PC',
                              icon: Icon(
                                Icons.share,
                                color: canOpen
                                    ? Colors.cyanAccent
                                    : Colors.white24,
                                size: 16,
                              ),
                              onPressed: canOpen
                                  ? () {
                                      final url = server.vaultUrl(key);
                                      Clipboard.setData(
                                        ClipboardData(text: url),
                                      );
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('Copied: $url'),
                                          backgroundColor: const Color(0xFF00E5FF),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  : null,
                            ),
                            PopupMenuButton<String>(
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white38,
                                size: 18,
                              ),
                              color: const Color(0xFF1E1E1E),
                              onSelected: (value) async {
                                if (value == 'details') {
                                  await showDialog<void>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: const Color(0xFF1A1A1A),
                                      title: const Text(
                                        'Dashboard details',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Key: $key',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(
                                            'Bhai: $associated',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                          if (buildId != null &&
                                              buildId.isNotEmpty)
                                            Text(
                                              'Build: $buildId',
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                              ),
                                            ),
                                          if (createdAt.isNotEmpty)
                                            Text(
                                              'Built: $createdAt',
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11,
                                              ),
                                            ),
                                          Text(
                                            'TTL: $ttlLabel',
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: canOpen
                                              ? () {
                                                  Navigator.pop(ctx);
                                                  _openDashboard(server, key);
                                                }
                                              : null,
                                          child: const Text('OPEN'),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            Navigator.pop(ctx);
                                            await _copyLink(server, key);
                                          },
                                          child: const Text('COPY LINK'),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            Navigator.pop(ctx);
                                            await _locateBroCode(key);
                                          },
                                          child: const Text('LOCATE BHAI'),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('CLOSE'),
                                        ),
                                      ],
                                    ),
                                  );
                                  return;
                                }
                                if (value == 'settings') {
                                  await showDialog<void>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: const Color(0xFF1A1A1A),
                                      title: const Text(
                                        'Dashboard settings',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final opt in [
                                            ('1 hour', Duration(hours: 1)),
                                            ('12 hours', Duration(hours: 12)),
                                            ('24 hours', Duration(hours: 24)),
                                            ('7 days', Duration(days: 7)),
                                          ])
                                            ListTile(
                                              title: Text(
                                                'TTL: ${opt.$1}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              onTap: () async {
                                                await ref
                                                    .read(telemetryBusProvider)
                                                    .setVaultTtl(key, opt.$2);
                                                if (ctx.mounted) {
                                                  Navigator.pop(ctx);
                                                }
                                                _refresh();
                                              },
                                            ),
                                          ListTile(
                                            title: const Text(
                                              'TTL: forever',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                            onTap: () async {
                                              await ref
                                                  .read(telemetryBusProvider)
                                                  .setVaultTtl(key, null);
                                              if (ctx.mounted) {
                                                Navigator.pop(ctx);
                                              }
                                              _refresh();
                                            },
                                          ),
                                          ListTile(
                                            title: const Text(
                                              'Export telemetry CSV',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                            onTap: () async {
                                              final bus = ref.read(
                                                telemetryBusProvider,
                                              );
                                              final csv = await bus
                                                  .exportTelemetryCsv();
                                              await bus.writeVaultData(
                                                'telemetry_export.csv',
                                                csv,
                                                mimeType: 'text/csv',
                                                ttl: const Duration(hours: 24),
                                              );
                                              if (ctx.mounted) {
                                                Navigator.pop(ctx);
                                              }
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'Wrote telemetry_export.csv (24h TTL)',
                                                    ),
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                          ListTile(
                                            title: const Text(
                                              'Stop / remove',
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                                fontSize: 13,
                                              ),
                                            ),
                                            onTap: () async {
                                              Navigator.pop(ctx);
                                              await _stopRemove(key);
                                            },
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('CLOSE'),
                                        ),
                                      ],
                                    ),
                                  );
                                  return;
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'details',
                                  child: Text(
                                    'Details',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'settings',
                                  child: Text(
                                    'Settings',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Stem used to match vault HTML keys to Bro Code names (e.g. Locator.html).
@visibleForTesting
String normalizeDashboardKeyStem(String key) {
  var s = key.trim();
  final slash = s.lastIndexOf('/');
  if (slash >= 0) s = s.substring(slash + 1);
  s = s.replaceAll(RegExp(r'\.html?$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'[_\-]+'), ' ');
  s = s.replaceAll(RegExp(r'\s*[Dd]ashboard\s*$'), '');
  return s.trim();
}

@visibleForTesting
AurBhaiAgent? findAgentForDashboardKey(
  List<AurBhaiAgent> agents,
  String vaultKey,
) {
  final stem = normalizeDashboardKeyStem(vaultKey).toLowerCase();
  if (stem.isEmpty) return null;
  final stemNs = stem.replaceAll(RegExp(r'\s+'), '');

  for (final a in agents) {
    if (a.name.toLowerCase() == stem) return a;
  }
  for (final a in agents) {
    if (a.name.toLowerCase().replaceAll(RegExp(r'\s+'), '') == stemNs) {
      return a;
    }
  }

  AurBhaiAgent? best;
  var bestScore = 0;
  for (final a in agents) {
    final n = a.name.toLowerCase();
    final nNs = n.replaceAll(RegExp(r'\s+'), '');
    var score = 0;
    if (n == stem || nNs == stemNs) {
      score = 100;
    } else if (n.contains(stem) || stem.contains(n)) {
      score = 50;
    } else if (nNs.contains(stemNs) || stemNs.contains(nNs)) {
      score = 40;
    }
    if (score > bestScore) {
      bestScore = score;
      best = a;
    }
  }
  return best;
}

/// MS-USER-ECOSYSTEM-UX1: Create-with-AI (Path A) + Manual Import (Path B).
class _AgentAuthoringSheet extends ConsumerStatefulWidget {
  const _AgentAuthoringSheet();
  @override
  ConsumerState<_AgentAuthoringSheet> createState() =>
      _AgentAuthoringSheetState();
}

class _AgentAuthoringSheetState extends ConsumerState<_AgentAuthoringSheet> {
  bool _aiMode = true;
  bool _busy = false;
  String? _error;
  AuthoredAgentDraft? _draft; // retains assetUpdates from the last AI generation

  final _promptCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _scriptCtrl = TextEditingController();
  final _schemaCtrl = TextEditingController();
  AgentSecurityClass _securityClass = AgentSecurityClass.c4Unverified;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _scriptCtrl.dispose();
    _schemaCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_promptCtrl.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await ref
          .read(llmServiceProvider)
          .authorAgent(_promptCtrl.text.trim());
      _draft = draft; // keep the full draft so _save() can forward assetUpdates
      _nameCtrl.text = draft.name;
      _descCtrl.text = draft.description;
      _scriptCtrl.text = draft.script;
      _schemaCtrl.text = draft.inputSchema.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(draft.inputSchema);
      // AI-authored agents register at C4 until promoted through due diligence.
      _securityClass = AgentSecurityClass.c4Unverified;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, AgentParameter> _parseSchema() {
    final text = _schemaCtrl.text.trim();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return decoded.map((key, value) {
      final field = value is Map ? value : <String, dynamic>{};
      return MapEntry(
        key,
        AgentParameter(
          type: field['type']?.toString() ?? 'string',
          description: field['description']?.toString() ?? '',
          required: field['required'] as bool? ?? true,
        ),
      );
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _scriptCtrl.text.trim().isEmpty) {
      setState(() => _error = "Name and script are required.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final schema = _parseSchema();
      final script = _scriptCtrl.text;
      final verification = ref.read(agentVerificationProvider);
      final scan = verification.scanScript(script);

      // Forward any LLM-generated vault assets (e.g. dashboard HTML) into the
      // registry so they are persisted alongside the script in the vault.
      final assets = _draft?.assetUpdates;

      await ref
          .read(jsAgentRegistryProvider)
          .saveAndRegisterAgent(
            name: name,
            description: _descCtrl.text.trim().isEmpty
                ? 'User-created agent.'
                : _descCtrl.text.trim(),
            inputSchema: schema,
            script: script,
            vaultAssets: assets != null && assets.isNotEmpty ? assets : null,
            securityClass: AgentSecurityClass.c4Unverified,
            source: BhaiCodeOrigin.self,
          );
      if (mounted) {
        Navigator.of(context).pop();
        if (scan.passed) {
          verification.requestPromotion(agentName: name, scan: scan);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '"$name" saved to Sandbox. Due diligence passed — promote when ready.',
              ),
            ),
          );
        } else {
          verification.requestPromotion(agentName: name, scan: scan);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '"$name" saved to Sandbox with due-diligence flags.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _error = "Save failed: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final systemBottom = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + systemBottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "INTRODUCE BHAI CODE TO BHAI LOG",
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _modeChip(
                  "AI AUTHORING",
                  _aiMode,
                  () => setState(() => _aiMode = true),
                ),
                const SizedBox(width: 8),
                _modeChip(
                  "MANUAL IMPORT",
                  !_aiMode,
                  () => setState(() => _aiMode = false),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_aiMode) ...[
              TextField(
                controller: _promptCtrl,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  hintText:
                      'Create an agent that... (e.g. "builds a live telemetry dashboard showing accelerometer over time")',
                  hintStyle: TextStyle(color: Colors.white24, fontSize: 12),
                  labelText: 'Describe the agent',
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF222222),
                  foregroundColor: Colors.greenAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _busy ? null : _generate,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(
                  _busy ? "GENERATING..." : "GENERATE WITH AI",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 28),
            ],
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Agent Name (PascalCase)',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Description',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _scriptCtrl,
              maxLines: 8,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'Courier',
              ),
              decoration: const InputDecoration(
                labelText: 'JavaScript source (async function execute(params))',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _schemaCtrl,
              maxLines: 4,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'Courier',
              ),
              decoration: const InputDecoration(
                labelText: 'Input schema JSON (optional)',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AgentSecurityClass>(
              initialValue: _securityClass,
              dropdownColor: const Color(0xFF1E1E1E),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Security Class',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              items: AgentSecurityClass.values
                  .where((c) => c != AgentSecurityClass.c3DueDiligence)
                  .map((c) => DropdownMenuItem(value: c, child: Text(c.label)))
                  .toList(),
              onChanged: (val) {
                if (val != null) setState(() => _securityClass = val);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _busy ? null : _save,
              child: const Text(
                "SAVE & REGISTER AGENT",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeChip(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? Colors.greenAccent.withValues(alpha: 0.15)
                : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? Colors.greenAccent : Colors.white12,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.greenAccent : Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

/// Agent detail + lifecycle (run / improve / export / delete) — MS-USER-ECOSYSTEM-ENG2.
class _AgentDetailSheet extends ConsumerStatefulWidget {
  final AurBhaiAgent agent;
  final bool fromSandbox;
  const _AgentDetailSheet({required this.agent, this.fromSandbox = false});
  @override
  ConsumerState<_AgentDetailSheet> createState() => _AgentDetailSheetState();
}

class _AgentDetailSheetState extends ConsumerState<_AgentDetailSheet> {
  bool _running = false;
  String? _runResult;
  bool _runWasError = false;
  String? _dashboardKey;
  String? _dashboardUrl;
  DueDiligenceResult? _scan;
  bool _scanLoaded = false;
  List<Map<String, String>> _relatedDashboards = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_scanLoaded) {
      _scanLoaded = true;
      _refreshScan();
      unawaited(_loadRelatedDashboards());
    }
  }

  void _refreshScan() {
    if (widget.agent is JsAgentAdapter) {
      _scan = ref
          .read(agentVerificationProvider)
          .scanScript((widget.agent as JsAgentAdapter).script);
    }
  }

  Future<void> _loadRelatedDashboards() async {
    final bus = ref.read(telemetryBusProvider);
    final entries = await bus.listVaultEntries(mimeType: 'text/html');
    final name = widget.agent.name.toLowerCase();
    final seen = <String>{};
    final related = entries.where((e) {
      final key = (e['key'] ?? '').toLowerCase();
      // Skip internal scoped asset keys (agent:<Name>:asset:<file>) — these are
      // vault-delivery keys, not URLs the local server actually serves.
      if (key.startsWith('agent:') && key.contains(':asset:')) return false;
      final matches = key.contains(name);
      if (!matches) return false;
      // Deduplicate by URL so the same HTML stored under multiple bare keys
      // (e.g. telemeter.html + telemetry_dashboard.html) shows as separate entries.
      final url = e['url'] ?? key;
      return seen.add(url);
    }).toList();
    if (mounted) setState(() => _relatedDashboards = related);
  }

  Future<void> _runDiligence() async {
    if (widget.agent is! JsAgentAdapter) return;
    final scan = ref
        .read(agentVerificationProvider)
        .scanScript((widget.agent as JsAgentAdapter).script);
    final passed = !scan.flagged;
    await ref
        .read(jsAgentRegistryProvider)
        .setDiligencePassed(widget.agent.name, passed);
    if (!mounted) return;
    setState(() => _scan = scan);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          passed
              ? 'Due diligence passed — marked on Sandbox card'
              : 'Due diligence flagged — see findings',
        ),
      ),
    );
  }

  Future<void> _promote() async {
    if (widget.agent is! JsAgentAdapter) return;
    final adapter = widget.agent as JsAgentAdapter;
    if (adapter.securityClass == AgentSecurityClass.c2Verified) return;

    final verification = ref.read(agentVerificationProvider);
    final scan = verification.scanScript(adapter.script);
    setState(() => _scan = scan);
    await showAgentPromotionDialog(
      context,
      ref,
      PendingPromotion(agentName: adapter.name, scan: scan),
      onPromoted: () {
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  Future<void> _run({bool sandbox = false}) async {
    if (!sandbox &&
        widget.agent is JsAgentAdapter &&
        !(widget.agent as JsAgentAdapter).canExecute) {
      setState(() {
        _runWasError = true;
        _runResult =
            'Promote to Mere Bhai before running against the real vault. Use TEST IN SANDBOX or IMPROVE first.';
        _dashboardKey = null;
        _dashboardUrl = null;
      });
      return;
    }

    setState(() {
      _running = true;
      _runResult = null;
      _runWasError = false;
      _dashboardKey = null;
      _dashboardUrl = null;
    });
    try {
      final String result;
      if (sandbox && widget.agent is JsAgentAdapter) {
        result = await (widget.agent as JsAgentAdapter).executeInSandbox(
          const {},
        );
      } else {
        result = await widget.agent.execute(const {});
      }
      final server = ref.read(localServerProvider);

      String? matchedKey;
      var isError = false;
      if (widget.agent is JsAgentAdapter) {
        final exec = (widget.agent as JsAgentAdapter).lastExecutionResult;
        isError = exec?.isError ?? false;
        final keys = exec?.vaultHtmlKeysWritten ?? const <String>[];
        if (!isError && keys.isNotEmpty) {
          matchedKey = keys.last;
        }
      }

      if (!isError &&
          (result.toLowerCase().contains('error') ||
              result.toLowerCase().contains('syntaxerror'))) {
        isError = true;
      }

      final url = (!sandbox && matchedKey != null && server.isRunning)
          ? server.vaultUrl(matchedKey)
          : null;

      setState(() {
        _runResult = sandbox ? '[SANDBOX] $result' : result;
        _runWasError = isError;
        _dashboardKey = matchedKey;
        _dashboardUrl = url;
      });
      if (!sandbox && matchedKey != null) {
        ref.read(vaultDashboardRefreshProvider).bump();
        await _loadRelatedDashboards();
      }
    } catch (e) {
      setState(() {
        _runResult = 'Error: $e';
        _runWasError = true;
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export() async {
    final registry = ref.read(jsAgentRegistryProvider);
    final bundle = await registry.exportAgentBundle(widget.agent.name);
    final text = bundle != null
        ? const JsonEncoder.withIndent('  ').convert(bundle)
        : (widget.agent as JsAgentAdapter).script;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent bundle copied to clipboard')),
      );
    }
  }

  Future<void> _delete() async {
    final label = widget.fromSandbox ? 'Remove from my device' : 'Delete';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(label, style: const TextStyle(color: Colors.white)),
        content: Text(
          widget.fromSandbox
              ? 'Removes your local Sandbox copy of "${widget.agent.name}". Does not delete shared pool / Friend Circle listings.'
              : 'Permanently remove "${widget.agent.name}" from this device?',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(label, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(jsAgentRegistryProvider).deleteAgent(widget.agent.name);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${widget.agent.name}" removed from device')),
      );
    }
  }

  void _openImprove() {
    final adapter = widget.agent as JsAgentAdapter;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ImproveAgentSheet(
        agent: adapter,
        lastRunError: _runWasError ? _runResult : null,
        lastRunResult: _runResult,
        dueDiligenceFindings: _scan?.findingMessages ?? const [],
      ),
    ).then((_) {
      if (mounted) setState(_refreshScan);
    });
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final isJs = agent is JsAgentAdapter;
    final canRun = !isJs || agent.canExecute;
    final builtAt = isJs ? (agent.updatedAt ?? agent.createdAt) : null;
    final scan = _scan;
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        mq.viewInsets.bottom + mq.padding.bottom + 16,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.92),
        child: Consumer(
          builder: (context, ref, _) {
            final themeService = ref.watch(themeServiceProvider);
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        isJs ? Icons.javascript : Icons.extension,
                        color: isJs ? Colors.amberAccent : Colors.greenAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          agent.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isJs) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: agent.source == BhaiCodeOrigin.pool
                                ? Colors.cyan.withValues(alpha: 0.15)
                                : agent.source == BhaiCodeOrigin.self
                                ? Colors.green.withValues(alpha: 0.15)
                                : Colors.purple.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: agent.source == BhaiCodeOrigin.pool
                                  ? Colors.cyanAccent.withValues(alpha: 0.4)
                                  : agent.source == BhaiCodeOrigin.self
                                  ? Colors.greenAccent.withValues(alpha: 0.4)
                                  : Colors.purpleAccent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            agent.displayHandle(
                              defaultUserHandle: ref.watch(byokServiceProvider).userHandle,
                            ),
                            style: TextStyle(
                              color: agent.source == BhaiCodeOrigin.pool
                                  ? Colors.cyanAccent
                                  : agent.source == BhaiCodeOrigin.self
                                  ? Colors.greenAccent
                                  : Colors.purpleAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: agent.securityClass == AgentSecurityClass.c2Verified
                                ? Colors.green.withValues(alpha: 0.15)
                                : Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: agent.securityClass == AgentSecurityClass.c2Verified
                                  ? Colors.greenAccent.withValues(alpha: 0.4)
                                  : Colors.amberAccent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            agent.securityClass == AgentSecurityClass.c2Verified
                                ? 'MERE BHAI (C2)'
                                : 'SANDBOX (C4)',
                            style: TextStyle(
                              color: agent.securityClass == AgentSecurityClass.c2Verified
                                  ? Colors.greenAccent
                                  : Colors.amberAccent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    agent.description,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                  if (builtAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Built ${DateFormat('yyyy-MM-dd HH:mm').format(builtAt.toLocal())}',
                      style: const TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                        fontFamily: 'Courier',
                      ),
                    ),
                  ],
                  if (agent is JsAgentAdapter && agent.lineage.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141820),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.cyanAccent.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.account_tree_outlined,
                                color: Colors.cyanAccent,
                                size: 16,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'REMIX LINEAGE & PROVENANCE',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          for (int i = agent.lineage.length - 1; i >= 0; i--) ...[
                            _buildLineageTimelineRow(
                              entry: agent.lineage[i],
                              isCurrent: i == agent.lineage.length - 1,
                              isOrigin: i == 0,
                            ),
                            if (i > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 7, top: 2, bottom: 2),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    width: 2,
                                    height: 10,
                                    color: Colors.cyanAccent.withValues(alpha: 0.3),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (isJs) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF181818),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.record_voice_over,
                                color: themeService.accentColor,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'BHAI WORDS & VOICE INVOCATION',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (agent.bhaiWords.isNotEmpty)
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: agent.bhaiWords.map((word) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF222222),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: themeService.accentColor.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Text(
                                  word,
                                  style: TextStyle(
                                    color: themeService.accentColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )).toList(),
                            )
                          else
                            const Text(
                              'No custom hot words defined.',
                              style: TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            'Example prompt: "${agent.invocationPrompt.isNotEmpty ? agent.invocationPrompt : 'Run ${agent.name}'}"',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF181818),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: (scan != null && scan.flagged)
                              ? Colors.amber.withValues(alpha: 0.4)
                              : Colors.greenAccent.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                (scan != null && scan.flagged)
                                    ? Icons.shield_outlined
                                    : Icons.verified_user,
                                color: (scan != null && scan.flagged)
                                    ? Colors.amber
                                    : Colors.greenAccent,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  '7-POINT DUE DILIGENCE AUDIT',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(50, 24),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: _runDiligence,
                                child: const Text(
                                  'RE-SCAN',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.amberAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (scan != null) ...[
                            ...scan.standardChecks.map((item) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.5),
                              child: Row(
                                children: [
                                  Icon(
                                    item.passed
                                        ? Icons.check_circle_outline
                                        : Icons.cancel_outlined,
                                    color: item.passed
                                        ? Colors.greenAccent
                                        : Colors.redAccent,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item.title,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    item.passed ? 'PASSED' : 'FLAGGED',
                                    style: TextStyle(
                                      color: item.passed
                                          ? Colors.greenAccent
                                          : Colors.redAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            )),
                            if (scan.findings.isNotEmpty) ...[
                              const Divider(color: Colors.white12, height: 16),
                              DueDiligenceFindingsList(scan: scan),
                            ],
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF181818),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.science_outlined,
                                color: Colors.orangeAccent,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'SANDBOX SIMULATION',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Test in Sandbox executes this code in an isolated QuickJS runner without granting access to ambient voice or sensitive vault data.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.orangeAccent,
                                side: const BorderSide(color: Colors.orangeAccent),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              onPressed: _running ? null : () => _run(sandbox: true),
                              icon: const Icon(Icons.play_circle_outline, size: 16),
                              label: const Text(
                                'TEST IN SANDBOX',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (agent.inputSchema.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      "PARAMETERS",
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...agent.inputSchema.entries.map(
                      (e) => Text(
                        "• ${e.key} (${e.value.type})${e.value.required ? '' : ' — optional'}: ${e.value.description}",
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                  ],
                  if (_relatedDashboards.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'DASHBOARDS',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ..._relatedDashboards.map((e) {
                      final key = e['key'] ?? '';
                      final server = ref.read(localServerProvider);
                      final url = server.isRunning ? server.vaultUrl(key) : null;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.greenAccent,
                            side: const BorderSide(color: Colors.greenAccent),
                          ),
                          onPressed: url == null
                              ? null
                              : () => launchVaultDashboard(context, url),
                          icon: const Icon(Icons.open_in_browser, size: 16),
                          label: Text(
                            key,
                            style: const TextStyle(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }),
                  ],
                  if (isJs) ...[
                    const SizedBox(height: 8),
                    Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                      ),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'INSPECT JAVASCRIPT SOURCE',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        children: [
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 160),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0D0D0D),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SingleChildScrollView(
                              child: Text(
                                agent.script,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                  fontFamily: 'Courier',
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_runResult != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _runWasError
                            ? const Color(0xFF2A1515)
                            : const Color(0xFF10261A),
                        borderRadius: BorderRadius.circular(8),
                        border: _runWasError
                            ? Border.all(
                                color: Colors.redAccent.withValues(alpha: 0.4),
                              )
                            : null,
                      ),
                      child: Text(
                        _runResult!,
                        style: TextStyle(
                          color: _runWasError
                              ? Colors.redAccent
                              : Colors.greenAccent,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (_runWasError && isJs) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _openImprove,
                        icon: const Icon(
                          Icons.tune,
                          color: Colors.lightBlueAccent,
                          size: 16,
                        ),
                        label: const Text(
                          'FIX WITH IMPROVE',
                          style: TextStyle(
                            color: Colors.lightBlueAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (_dashboardUrl != null && !_runWasError) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.greenAccent,
                          side: const BorderSide(color: Colors.greenAccent),
                        ),
                        onPressed: () =>
                            launchVaultDashboard(context, _dashboardUrl!),
                        icon: const Icon(Icons.open_in_browser, size: 16),
                        label: Text(
                          'OPEN DASHBOARD (${_dashboardKey ?? ''})',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: canRun
                              ? Colors.greenAccent
                              : Colors.white24,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 12,
                          ),
                        ),
                        onPressed: (_running || !canRun) ? null : () => _run(),
                        icon: _running
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                canRun ? Icons.play_arrow : Icons.lock,
                                size: 18,
                              ),
                        label: Text(
                          _running
                              ? 'RUNNING'
                              : (canRun ? 'RUN' : 'RUN (MERE BHAI ONLY)'),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isJs)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.lightBlueAccent,
                            side: const BorderSide(color: Colors.lightBlueAccent),
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                          onPressed: _openImprove,
                          icon: const Icon(Icons.tune, size: 16),
                          label: const Text(
                            'IMPROVE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      if (isJs &&
                          agent.securityClass != AgentSecurityClass.c2Verified)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.amber,
                            side: const BorderSide(color: Colors.amber),
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                          onPressed: _promote,
                          icon: const Icon(Icons.verified_user, size: 16),
                          label: const Text(
                            'PROMOTE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      if (isJs)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.greenAccent,
                            side: const BorderSide(color: Colors.greenAccent),
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                          onPressed: () async {
                            final result = await showPublishToCircleDialog(context);
                            if (result == null || !mounted) return;
                            try {
                              await ref
                                  .read(circleRegistryProvider)
                                  .publishAgent(
                                    agent.name,
                                    license: result.license,
                                    access: result.access,
                                  );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${agent.name} published to Friend Circle (${result.license})',
                                  ),
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Publish failed: $e')),
                              );
                            }
                          },
                          icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                          label: const Text(
                            'PUBLISH',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      if (isJs)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                          onPressed: _export,
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text(
                            'EXPORT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      if (isJs)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 12,
                            ),
                          ),
                          onPressed: _delete,
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: Text(
                            widget.fromSandbox ? 'REMOVE FROM DEVICE' : 'DELETE',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLineageTimelineRow({
    required LineageEntry entry,
    required bool isCurrent,
    required bool isOrigin,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isCurrent
              ? Icons.radio_button_checked
              : (isOrigin ? Icons.star_rounded : Icons.subdirectory_arrow_right),
          size: 16,
          color: isCurrent
              ? Colors.cyanAccent
              : (isOrigin ? Colors.amberAccent : Colors.white54),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    entry.displayHandle,
                    style: TextStyle(
                      color: isCurrent ? Colors.cyanAccent : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'v${entry.version}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (isOrigin) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.amberAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Colors.amberAccent.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Text(
                        'ORIGIN',
                        style: TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (entry.note.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  entry.note,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Live visual authoring checklist + BUILD gate.
class _AuthoringPanelSheet extends ConsumerStatefulWidget {
  const _AuthoringPanelSheet();
  @override
  ConsumerState<_AuthoringPanelSheet> createState() =>
      _AuthoringPanelSheetState();
}

class _AuthoringPanelSheetState extends ConsumerState<_AuthoringPanelSheet> {
  AppSpecSlot? _editingSlot;
  final _editCtrl = TextEditingController();
  bool _building = false;

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  String _statusLabel(SpecField field) {
    switch (field.status) {
      case SlotStatus.empty:
        return 'empty';
      case SlotStatus.proposed:
        return 'suggested';
      case SlotStatus.confirmed:
        return 'confirmed';
    }
  }

  Color _statusColor(SpecField field) {
    switch (field.status) {
      case SlotStatus.empty:
        return Colors.white24;
      case SlotStatus.proposed:
        return Colors.amber;
      case SlotStatus.confirmed:
        return Colors.greenAccent;
    }
  }

  String _slotAnswer(AppSpec spec, AppSpecSlot slot) {
    switch (slot) {
      case AppSpecSlot.parameters:
        if (spec.parameters.isEmpty) return '—';
        return spec.parameters.map((p) => '${p.name} (${p.type})').join(', ');
      case AppSpecSlot.externalIntegrations:
        if (spec.externalIntegrations.isEmpty) return '—';
        return spec.externalIntegrations
            .map((e) => '${e.platform}: ${e.action}')
            .join(', ');
      default:
        return spec.fieldFor(slot).value ?? '—';
    }
  }

  Future<void> _build() async {
    setState(() => _building = true);
    try {
      await ref.read(voiceHandshakeProvider).buildFromReview();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(conversationalSessionProvider);
    final spec = session.appSpec;
    final slots = spec.relevantSlots();
    final canBuild =
        spec.purpose.hasValue &&
        spec.behaviorResponse.hasValue &&
        (session.isInReview || spec.allRelevantConfirmed);
    final scan = session.lastScan;
    final mq = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        mq.viewInsets.bottom + mq.padding.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'AUTHORING PANEL',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                if (session.isInReview)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'REVIEW',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap any question to edit. Voice answers update this list live.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < slots.length; i++) ...[
              _buildSlotRow(session, spec, slots[i], i + 1),
              const SizedBox(height: 8),
            ],
            const Divider(color: Colors.white12, height: 28),
            const Text(
              'FINAL REVIEW',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              spec.capturedSlotsRecap().isEmpty
                  ? 'Nothing captured yet.'
                  : spec.capturedSlotsRecap(),
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
            if (scan != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scan.passed
                      ? const Color(0xFF10261A)
                      : const Color(0xFF2A1A10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  scan.passed
                      ? 'Due diligence: PASSED'
                      : 'Due diligence flagged: ${scan.findings.join(' ')}',
                  style: TextStyle(
                    color: scan.passed ? Colors.greenAccent : Colors.amber,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: (canBuild && !_building) ? _build : null,
              icon: _building
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.build, size: 18),
              label: Text(
                _building ? 'BUILDING…' : 'BUILD AGENT',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            if (!canBuild)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Fill required slots (purpose + behavior at minimum). When ready, the session enters review — then Build.',
                  style: TextStyle(color: Colors.white30, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlotRow(
    ConversationalSessionService session,
    AppSpec spec,
    AppSpecSlot slot,
    int index,
  ) {
    final editable =
        slot != AppSpecSlot.parameters &&
        slot != AppSpecSlot.externalIntegrations;
    final isEditing = _editingSlot == slot;
    SpecField? field;
    try {
      field = spec.fieldFor(slot);
    } catch (_) {
      field = null;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Q$index',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AuthorPrompts.slotQuestion(slot),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
              if (field != null)
                Text(
                  _statusLabel(field),
                  style: TextStyle(color: _statusColor(field), fontSize: 9),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (isEditing) ...[
            TextField(
              controller: _editCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 3,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Your answer…',
                hintStyle: TextStyle(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    session.updateSlotValue(slot, _editCtrl.text);
                    if (session.appSpec.allRelevantConfirmed) {
                      session.enterReview();
                    }
                    setState(() => _editingSlot = null);
                  },
                  child: const Text(
                    'SAVE',
                    style: TextStyle(color: Colors.greenAccent),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _editingSlot = null),
                  child: const Text(
                    'CANCEL',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              ],
            ),
          ] else ...[
            GestureDetector(
              onTap: editable
                  ? () {
                      _editCtrl.text = field?.value ?? '';
                      setState(() => _editingSlot = slot);
                    }
                  : null,
              child: Text(
                _slotAnswer(spec, slot),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  decoration: editable ? TextDecoration.underline : null,
                  decorationColor: Colors.white24,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// In-UI refine flow for an existing JS agent.
class _ImproveAgentSheet extends ConsumerStatefulWidget {
  final JsAgentAdapter agent;
  final String? lastRunError;
  final String? lastRunResult;
  final List<String> dueDiligenceFindings;

  const _ImproveAgentSheet({
    required this.agent,
    this.lastRunError,
    this.lastRunResult,
    this.dueDiligenceFindings = const [],
  });

  @override
  ConsumerState<_ImproveAgentSheet> createState() => _ImproveAgentSheetState();
}

class _ImproveAgentSheetState extends ConsumerState<_ImproveAgentSheet> {
  final _changeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  AuthoredAgentDraft? _draft;
  bool _verified = false;
  final List<String> _progressLog = [];
  int _attempt = 0;
  String? _lastFailureForRetry;
  int _contextUsed = 0;
  int _contextBudget = kDefaultContextBudgetTokens;
  int _lastTurnsUsed = 0;
  BroCodeAgentResult? _lastResult;
  final _progressScroll = ScrollController();
  late BroCodeImproveSession _session;

  /// Script to continue from on Retry (last unverified / verified draft).
  String? _workingScript;

  @override
  void initState() {
    super.initState();
    _session = BroCodeImproveSession(
      agentName: widget.agent.name,
      startedAt: DateTime.now(),
    );
    final chips = _suggestedChips();
    if (chips.isNotEmpty) {
      _changeCtrl.text = chips.first;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSessionFromVault();
    });
  }

  Future<void> _loadSessionFromVault() async {
    try {
      final bus = ref.read(telemetryBusProvider);
      final key = BroCodeImproveSession.vaultKeyFor(widget.agent.name);
      final asset = await bus.readVaultData(key);
      if (asset == null || !mounted) return;
      final decoded = jsonDecode(asset['value']!) as Map<String, dynamic>;
      final loaded = BroCodeImproveSession.fromJson(decoded);
      setState(() {
        _session = loaded;
        _workingScript = loaded.lastWorkingScript;
        _attempt = loaded.attempts.length;
        if (_changeCtrl.text.trim().isEmpty &&
            loaded.distinctChangeRequests().isNotEmpty) {
          _changeCtrl.text = loaded.distinctChangeRequests().last;
        }
      });
      _appendProgress(
        'Restored ${loaded.attempts.length} prior IMPROVE attempt(s) '
        '(${loaded.distinctChangeRequests().length} distinct request(s))',
      );
    } catch (e) {
      debugPrint('[IMPROVE] Failed to load session history: $e');
    }
  }

  Future<void> _persistSession() async {
    try {
      final dropped = _session.trimToMaxAttempts();
      if (dropped > 0) {
        _appendProgress(
          'Trimmed $dropped oldest IMPROVE attempt(s) '
          '(cap ${BroCodeImproveSession.maxPersistedAttempts})',
        );
      }
      final bus = ref.read(telemetryBusProvider);
      await bus.writeVaultData(
        BroCodeImproveSession.vaultKeyFor(widget.agent.name),
        _session.toJsonString(pretty: false),
        mimeType: BroCodeImproveSession.vaultMime,
      );
    } catch (e) {
      debugPrint('[IMPROVE] Failed to persist session history: $e');
    }
  }

  Future<void> _startFreshSession() async {
    if (_busy) return;
    try {
      final bus = ref.read(telemetryBusProvider);
      await bus.deleteVaultData(
        BroCodeImproveSession.vaultKeyFor(widget.agent.name),
      );
    } catch (e) {
      debugPrint('[IMPROVE] Failed to delete session vault: $e');
    }
    if (!mounted) return;
    setState(() {
      _session = BroCodeImproveSession(
        agentName: widget.agent.name,
        startedAt: DateTime.now(),
      );
      _attempt = 0;
      _workingScript = null;
      _progressLog.clear();
      _error = null;
      _draft = null;
      _verified = false;
      _lastFailureForRetry = null;
      _lastResult = null;
      _lastTurnsUsed = 0;
      _contextUsed = 0;
    });
    _appendProgress(
      'Started fresh IMPROVE session — seeding from vault Bhai Code on next Run.',
    );
  }

  BroCodeImproveAttempt _buildAttempt({
    required String scriptBefore,
    required String changeRequest,
    required List<String> activitySlice,
    required bool verified,
    required String outcomeMessage,
    required String scriptAfter,
    Map<String, String> assetsAfter = const {},
    BroCodeAgentResult? diagnostics,
  }) {
    return BroCodeImproveAttempt(
      attemptNumber: _session.attempts.length + 1,
      completedAt: DateTime.now(),
      changeRequest: changeRequest,
      verified: verified,
      outcomeMessage: outcomeMessage,
      turnsUsed: diagnostics?.turnsUsed ?? _lastTurnsUsed,
      estimatedTokensUsed: diagnostics?.estimatedTokensUsed ?? _contextUsed,
      agentActivity: activitySlice,
      scriptBefore: scriptBefore,
      scriptAfter: scriptAfter,
      assetsAfter: assetsAfter,
      lastRunError: widget.lastRunError,
      dueDiligenceFindings: widget.dueDiligenceFindings,
      baselineSyntax: diagnostics?.baselineSyntax,
      lastSyntaxError: diagnostics?.lastSyntaxError,
      lastSandboxError: diagnostics?.lastSandboxError,
      lastFormatError: diagnostics?.lastFormatError,
      lastStyleError: diagnostics?.lastStyleError,
      lastPolicyError: diagnostics?.lastPolicyError,
      failingObservations: diagnostics?.failingObservations ?? const [],
    );
  }

  @override
  void dispose() {
    _changeCtrl.dispose();
    _progressScroll.dispose();
    super.dispose();
  }

  void _appendProgress(String message) {
    if (!mounted) return;
    setState(() => _progressLog.add(message));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_progressScroll.hasClients) return;
      _progressScroll.animateTo(
        _progressScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _onContextUpdate(int used, int budget) {
    if (!mounted) return;
    setState(() {
      _contextUsed = used;
      _contextBudget = budget;
    });
  }

  List<String> _suggestedChips() {
    final suggestions = <String>[];
    final err = widget.lastRunError ?? '';
    if (err.toLowerCase().contains('syntaxerror') ||
        err.toLowerCase().contains('syntax')) {
      suggestions.add(
        'Fix the SyntaxError in the agent script so execute() runs cleanly in QuickJS.',
      );
    } else if (err.trim().isNotEmpty) {
      suggestions.add('Fix this runtime error: $err');
    }

    for (final f in widget.dueDiligenceFindings) {
      if (f.toLowerCase().contains('browser') ||
          f.toLowerCase().contains('dom') ||
          f.toLowerCase().contains('fetch')) {
        suggestions.add(
          'Remove browser/DOM APIs (document, window, fetch) from the QuickJS sandbox script. Keep HTML dashboard templates self-contained; use only System.querySQL / System.writeVault / System.sendHTTP / System.log in execute().',
        );
      } else {
        suggestions.add('Resolve due-diligence finding: $f');
      }
    }

    if (err.toLowerCase().contains('vault') ||
        (widget.lastRunResult?.toLowerCase().contains('/vault/') ?? false)) {
      suggestions.add(
        'Dashboard link should point users to the Vault Dashboards panel (or a full edge-server URL), not a bare relative /vault/ path or a stale HTML file from another agent.',
      );
    }

    final seen = <String>{};
    return suggestions.where((s) => seen.add(s)).toList();
  }

  Future<void> _generatePatch({bool isRetry = false}) async {
    if (_changeCtrl.text.trim().isEmpty) return;
    final changeRequest = _changeCtrl.text.trim();
    final activityStart = _progressLog.length;
    final scriptBefore =
        _workingScript ?? _draft?.script ?? widget.agent.script;

    setState(() {
      _busy = true;
      _error = null;
      _draft = null;
      _verified = false;
      if (!isRetry) {
        // Keep durable session; only clear live log for a fresh RUN.
        _progressLog.clear();
        _lastFailureForRetry = null;
        _contextUsed = 0;
      } else {
        _attempt++;
        _progressLog.add('── Retry $_attempt ──');
      }
    });
    try {
      final registry = ref.read(jsAgentRegistryProvider);
      final assets = await registry.readAgentAssets(widget.agent.name);
      if (assets.isNotEmpty) {
        _appendProgress('Loaded ${assets.length} related vault asset(s)');
      }

      // Retries continue from last working draft, not vault baseline.
      final seedScript = isRetry
          ? (_workingScript ??
                _session.lastWorkingScript ??
                widget.agent.script)
          : (_workingScript ?? widget.agent.script);

      final workspace = BroCodeWorkspace(
        name: widget.agent.name,
        description: widget.agent.description,
        inputSchema: widget.agent.inputSchema.map(
          (k, v) => MapEntry(k, v.toJson()),
        ),
        script: seedScript,
        assets: assets,
      );

      _appendProgress('Handing off to coding agent (tools + observe + retry)…');
      if (isRetry && seedScript != widget.agent.script) {
        _appendProgress(
          'Continuing from prior working draft (${seedScript.length} chars)',
        );
      }

      final result = await ref
          .read(broCodeCodingAgentProvider)
          .improve(
            workspace: workspace,
            changeRequest: changeRequest,
            lastRunError: widget.lastRunError,
            dueDiligenceFindings: widget.dueDiligenceFindings,
            priorFailureContext: isRetry ? _lastFailureForRetry : null,
            onProgress: _appendProgress,
            onContextUpdate: _onContextUpdate,
          );

      final scriptAfter = result.draft?.script ?? workspace.script;
      final assetsAfter =
          result.draft?.assetUpdates ??
          Map<String, String>.from(workspace.assets);

      setState(() {
        _draft = result.draft;
        _verified = result.verified;
        _contextUsed = result.estimatedTokensUsed;
        _contextBudget = result.contextBudgetTokens;
        _lastTurnsUsed = result.turnsUsed;
        _lastResult = result;
        _workingScript = scriptAfter;
      });

      final activitySlice = _progressLog.length > activityStart
          ? _progressLog.sublist(activityStart)
          : List<String>.from(_progressLog);

      final attempt = _buildAttempt(
        scriptBefore: scriptBefore,
        changeRequest: changeRequest,
        activitySlice: activitySlice,
        verified: result.verified,
        outcomeMessage: result.message,
        scriptAfter: scriptAfter,
        assetsAfter: assetsAfter,
        diagnostics: result,
      );
      final dropped = _session.addAttempt(attempt);
      if (dropped > 0) {
        _appendProgress(
          'Trimmed $dropped oldest IMPROVE attempt(s) '
          '(cap ${BroCodeImproveSession.maxPersistedAttempts})',
        );
      }
      await _persistSession();

      if (result.verified) {
        _appendProgress(
          'Ready for APPLY (${result.turnsUsed} turns, '
          'est. context $_contextUsed tokens)',
        );
      } else {
        _lastFailureForRetry = result.message;
        _appendProgress('Not verified: ${result.message}');
        setState(() => _error = result.message);
      }
    } catch (e) {
      final friendly = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      _lastFailureForRetry = friendly;
      _appendProgress('Failed: $friendly');

      final activitySlice = _progressLog.length > activityStart
          ? _progressLog.sublist(activityStart)
          : List<String>.from(_progressLog);
      final attempt = _buildAttempt(
        scriptBefore: scriptBefore,
        changeRequest: changeRequest,
        activitySlice: activitySlice,
        verified: false,
        outcomeMessage: friendly,
        scriptAfter: _workingScript ?? scriptBefore,
      );
      final dropped = _session.addAttempt(attempt);
      if (dropped > 0) {
        _appendProgress(
          'Trimmed $dropped oldest IMPROVE attempt(s) '
          '(cap ${BroCodeImproveSession.maxPersistedAttempts})',
        );
      }
      await _persistSession();

      setState(() => _error = friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  BroCodeFixtureReport _buildDiagnosticReport() {
    final workspace = BroCodeWorkspace(
      name: widget.agent.name,
      description: widget.agent.description,
      inputSchema: widget.agent.inputSchema.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
      script: _draft?.script ?? _workingScript ?? widget.agent.script,
      // Assets filled asynchronously by callers that need vault assets.
      assets: const {},
    );

    final diagnostics = _lastResult;
    return BroCodeFixtureReport(
      exportedAt: DateTime.now(),
      appVersion: '1.0.0+1',
      workspace: workspace,
      changeRequest: _changeCtrl.text.trim(),
      lastRunError: widget.lastRunError,
      dueDiligenceFindings: widget.dueDiligenceFindings,
      agentActivity: List<String>.from(_progressLog),
      failureMessage: _error ?? _lastFailureForRetry ?? 'IMPROVE not verified',
      turnsUsed: _lastTurnsUsed,
      estimatedTokensUsed: _contextUsed,
      expectSyntaxOk: false,
      expectSandboxOk: false,
      baselineSyntax: diagnostics?.baselineSyntax,
      lastSyntaxError: diagnostics?.lastSyntaxError,
      lastSandboxError: diagnostics?.lastSandboxError,
      lastFormatError: diagnostics?.lastFormatError,
      lastStyleError: diagnostics?.lastStyleError,
      lastPolicyError: diagnostics?.lastPolicyError,
      failingObservations: diagnostics?.failingObservations ?? const [],
      session: _session,
      attemptNumber: _session.attempts.isEmpty
          ? null
          : _session.attempts.last.attemptNumber,
      verified: _verified,
    );
  }

  Future<BroCodeFixtureReport> _buildDiagnosticReportWithAssets() async {
    final registry = ref.read(jsAgentRegistryProvider);
    final assets = await registry.readAgentAssets(widget.agent.name);
    final draftAssets = _draft?.assetUpdates;
    final merged = <String, String>{
      ...assets,
      if (draftAssets != null) ...draftAssets,
    };
    final base = _buildDiagnosticReport();

    AuthoringTrace? authoringTrace;
    String? authoringMissing;
    try {
      final entry = await ref
          .read(telemetryBusProvider)
          .readVaultData(AuthoringTrace.vaultKeyFor(widget.agent.name));
      final raw = entry?['value'];
      if (raw != null && raw.trim().isNotEmpty) {
        authoringTrace = AuthoringTrace.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } else {
        authoringMissing =
            'No frozen authoringTrace in vault (imported Bro or pre-S15 build).';
      }
    } catch (e) {
      authoringMissing = 'Failed to load authoringTrace: $e';
    }

    return BroCodeFixtureReport(
      exportedAt: base.exportedAt,
      appVersion: base.appVersion,
      workspace: BroCodeWorkspace(
        name: base.workspace.name,
        description: base.workspace.description,
        inputSchema: base.workspace.inputSchema,
        script: base.workspace.script,
        assets: merged,
      ),
      changeRequest: base.changeRequest,
      lastRunError: base.lastRunError,
      dueDiligenceFindings: base.dueDiligenceFindings,
      agentActivity: base.agentActivity,
      failureMessage: base.failureMessage,
      turnsUsed: base.turnsUsed,
      estimatedTokensUsed: base.estimatedTokensUsed,
      expectSyntaxOk: base.expectSyntaxOk,
      expectSandboxOk: base.expectSandboxOk,
      baselineSyntax: base.baselineSyntax,
      lastSyntaxError: base.lastSyntaxError,
      lastSandboxError: base.lastSandboxError,
      lastFormatError: base.lastFormatError,
      lastStyleError: base.lastStyleError,
      lastPolicyError: base.lastPolicyError,
      failingObservations: base.failingObservations,
      session: base.session,
      attemptNumber: base.attemptNumber,
      verified: base.verified,
      authoringTrace: authoringTrace,
      authoringTraceMissingReason: authoringMissing,
    );
  }

  Future<void> _copyDiagnosticJson() async {
    final report = await _buildDiagnosticReportWithAssets();

    await Clipboard.setData(ClipboardData(text: report.toJsonString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Diagnostic JSON copied (${_session.attempts.length} attempt(s), '
            '${_session.distinctChangeRequests().length} request(s)). '
            'Paste into test/fixtures/bro_code/ on your dev machine.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _captureFixtureToDisk() async {
    setState(() => _busy = true);
    try {
      final report = await _buildDiagnosticReportWithAssets();
      final result = await BroCodeFixtureCapture.writeBundle(report);
      if (!mounted) return;

      // Always leave the pull command on the clipboard for the PC workflow.
      final clipboardText = result.wroteToRepoFixtures
          ? 'Fixture already in repo: test/fixtures/bro_code/${result.bundleFileName}'
          : 'dart run tool/pull_bro_code_fixture.dart';
      await Clipboard.setData(ClipboardData(text: clipboardText));

      _appendProgress('CAPTURE FIXTURE → ${result.bundleFileName}');
      if (result.wroteToRepoFixtures) {
        _appendProgress(
          'Saved into repo fixtures (desktop). Run fixture / E2E tests next.',
        );
      } else {
        _appendProgress(
          'Saved on device (phone cannot write your Windows repo).',
        );
        _appendProgress(
          'On PC: dart run tool/pull_bro_code_fixture.dart  (command copied)',
        );
        _appendProgress(
          'Then tell Cursor to investigate that *.bundle.json — no paste needed.',
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.wroteToRepoFixtures
                ? 'Fixture in repo: ${result.bundleFileName}'
                : 'Fixture on phone: ${result.bundleFileName}\n'
                      'Pull command copied. On PC run:\n'
                      'dart run tool/pull_bro_code_fixture.dart',
          ),
          duration: const Duration(seconds: 10),
          backgroundColor: Colors.teal.shade900,
        ),
      );
    } catch (e) {
      _appendProgress('CAPTURE FIXTURE failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture Fixture failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final registry = ref.read(jsAgentRegistryProvider);
      await registry.refineAndReregister(
        name: widget.agent.name,
        script: draft.script,
        description: draft.description,
        inputSchema: draft.toAgentParameters(),
        assetUpdates: draft.assetUpdates,
      );
      final verification = ref.read(agentVerificationProvider);
      final scan = verification.scanScript(draft.script);
      verification.requestPromotion(
        agentName: widget.agent.name,
        scan: scan,
        isRefinement: true,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              scan.passed
                  ? '${widget.agent.name} updated — due diligence passed. Promote to Mere Bhai to enable RUN.'
                  : '${widget.agent.name} updated but still flagged. Review findings and improve again, or force-promote.',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final chips = _suggestedChips();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        mq.viewInsets.bottom + mq.padding.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'IMPROVE ${widget.agent.name.toUpperCase()}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                ContextUsageGauge(
                  usedTokens: _contextUsed,
                  budgetTokens: _contextBudget,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'A coding agent will edit, test in the sandbox, and retry until verified. '
              'Live steps appear below — you can leave APPLY until the agent finishes green.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'SUGGESTED FEEDBACK',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: chips
                    .map(
                      (chip) => ActionChip(
                        label: Text(
                          chip.length > 80 ? '${chip.substring(0, 80)}…' : chip,
                          style: const TextStyle(fontSize: 10),
                        ),
                        backgroundColor: const Color(0xFF222222),
                        labelStyle: const TextStyle(
                          color: Colors.lightBlueAccent,
                        ),
                        onPressed: () =>
                            setState(() => _changeCtrl.text = chip),
                      ),
                    )
                    .toList(),
              ),
            ],
            if (widget.lastRunError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A1515),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Last run error:\n${widget.lastRunError}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ),
            ],
            if (widget.dueDiligenceFindings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A1A10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Due diligence findings:',
                      style: TextStyle(color: Colors.amber, fontSize: 11),
                    ),
                    ...widget.dueDiligenceFindings.map(
                      (f) => Text(
                        '• $f',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _changeCtrl,
              maxLines: 4,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'What should change?',
                labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                hintText:
                    'e.g. Fix SyntaxError; remove browser APIs from sandbox; fix dashboard output.',
                hintStyle: TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF222222),
                foregroundColor: Colors.lightBlueAccent,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _busy ? null : () => _generatePatch(),

              icon: _busy && !_verified
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_high, size: 18),
              label: Text(
                _busy && !_verified
                    ? 'CODING AGENT WORKING…'
                    : 'RUN CODING AGENT',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            if (_session.isLarge && !_busy) ...[
              const SizedBox(height: 8),
              Text(
                'Session has ${_session.attempts.length} attempt(s) — '
                'Start fresh to discard prior drafts and history.',
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 10,
                ),
              ),
              TextButton(
                onPressed: _startFreshSession,
                child: const Text(
                  'START FRESH',
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 8),
              const Text(
                'Stay on this sheet — steps and heartbeats update while the model thinks.',
                style: TextStyle(color: Colors.white30, fontSize: 10),
              ),
            ],
            if (_progressLog.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text(
                    'AGENT ACTIVITY',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  if (_contextUsed > 0)
                    Text(
                      'Est. $_contextUsed / $_contextBudget',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _busy
                        ? Colors.lightBlueAccent.withValues(alpha: 0.4)
                        : Colors.white12,
                  ),
                ),
                child: ListView.builder(
                  controller: _progressScroll,
                  itemCount: _progressLog.length,
                  itemBuilder: (context, i) {
                    final line = _progressLog[i];
                    final isHeartbeat = line.contains('Still waiting');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        isHeartbeat ? '… $line' : '• $line',
                        style: TextStyle(
                          color: isHeartbeat ? Colors.white38 : Colors.white70,
                          fontSize: 11,
                          fontFamily: 'Courier',
                          fontStyle: isHeartbeat
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (_draft != null && _verified) ...[
              const SizedBox(height: 16),
              const Text(
                'READY DRAFT',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _draft!.notes ?? 'Sandbox + syntax verified.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              if (_draft!.assetUpdates.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Also updates asset(s): ${_draft!.assetUpdates.keys.join(', ')}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _draft!.script,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 10,
                      fontFamily: 'Courier',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _busy ? null : _apply,
                child: Text(
                  _busy ? 'APPLYING…' : 'APPLY TO VAULT (SABKE BHAI)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            if (_error != null ||
                (!_verified && _progressLog.isNotEmpty && !_busy)) ...[
              const SizedBox(height: 12),
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              if (_session.isLarge) ...[
                const SizedBox(height: 8),
                const Text(
                  'Session is large — Start fresh to discard prior drafts and history.',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 10),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Improvement did not succeed yet. Retry continues from the last draft. '
                'Start fresh reseeds from the vault Bhai Code. Or copy a diagnostic JSON.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
              const SizedBox(height: 4),
              const Text(
                'This copies a diagnostic JSON report to your clipboard. Nothing is uploaded automatically.',
                style: TextStyle(color: Colors.amberAccent, fontSize: 10),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _copyDiagnosticJson,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.amberAccent,
                  side: const BorderSide(color: Colors.amberAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.content_copy_outlined, size: 18),
                label: const Text(
                  'COPY DIAGNOSTIC JSON',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _captureFixtureToDisk,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.tealAccent,
                    side: const BorderSide(color: Colors.tealAccent),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.save_alt_outlined, size: 18),
                  label: const Text(
                    'CAPTURE FIXTURE',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final reporterNote = await showDialog<String>(
                          context: context,
                          builder: (ctx) => const _SendReportNoteDialog(),
                        );
                        if (reporterNote == null || !mounted) return;
                        setState(() => _busy = true);
                        try {
                          final report =
                              await _buildDiagnosticReportWithAssets();
                          final created = await ref
                              .read(issueReportServiceProvider)
                              .sendReport(
                                report: report,
                                title:
                                    'Bhai Code: ${widget.agent.name} — ${report.failureMessage}',
                                reporterNote: reporterNote,
                              );
                          _appendProgress(
                            'Report sent → GitHub #${created.githubIssueNumber}',
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Report #${created.githubIssueNumber} created',
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          _appendProgress('Send report failed: $e');
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orangeAccent,
                  side: const BorderSide(color: Colors.orangeAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: const Text(
                  'SEND REPORT TO CIRCLE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => _generatePatch(isRetry: true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  side: const BorderSide(color: Colors.lightBlueAccent),
                ),
                child: const Text(
                  'RETRY AGENT',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed:
                    (_busy ||
                        (_session.attempts.isEmpty && _workingScript == null))
                    ? null
                    : _startFreshSession,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orangeAccent,
                  side: const BorderSide(color: Colors.orangeAccent),
                ),
                child: const Text(
                  'START FRESH',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Owns [TextEditingController] for the SEND REPORT dialog so dispose runs
/// only after the route is fully removed (avoids `_dependents.isEmpty`).
class _SendReportNoteDialog extends StatefulWidget {
  const _SendReportNoteDialog();

  @override
  State<_SendReportNoteDialog> createState() => _SendReportNoteDialogState();
}

class _SendReportNoteDialogState extends State<_SendReportNoteDialog> {
  late final TextEditingController _noteCtrl;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Text('Send report', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppConfig.issueSendConsent,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              maxLines: 4,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: AppConfig.issueReporterNoteLabel,
                hintText: AppConfig.issueReporterNoteHint,
                labelStyle: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _noteCtrl.text),
          child: const Text('SEND'),
        ),
      ],
    );
  }
}
