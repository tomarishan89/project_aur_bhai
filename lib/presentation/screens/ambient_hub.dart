import 'dart:convert';
import 'dart:io';
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
import '../../core/services/llm_service.dart';
import '../../core/services/llm/llm_provider.dart';
import '../../core/services/llm/llm_provider_factory.dart';
import '../../core/services/local_server_service.dart';
import '../../core/services/js_agent_registry.dart';
import '../../core/services/conversational_session_service.dart';
import '../../core/services/agent_verification_service.dart';
import '../../core/services/device_auth_service.dart';
import '../../core/services/telemetry_bus.dart';
import '../../core/services/app_spec.dart';
import '../../core/services/author_prompts.dart';
import '../../core/pipeline/bro_code_coding_agent.dart';
import '../../core/pipeline/bro_code_fixture_report.dart';
import '../../core/pipeline/bro_code_workspace.dart';
import '../../core/pipeline/context_estimate.dart';
import '../widgets/context_usage_gauge.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

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

/// Opens [url] in the host's default browser (desktop) or copies it (mobile).
Future<void> launchInBrowser(BuildContext context, String url) async {
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
      SnackBar(content: Text('URL copied: $url')),
    );
  }
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
        title: const Text('Promote Agent?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${pending.agentName} passed due diligence. Promote to Verified (C2)?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('LATER')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('PROMOTE', style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
    if (promote == true) {
      final ok = await verification.promoteToVerified(
        registry: ref.read(jsAgentRegistryProvider),
        agentName: pending.agentName,
        priorScan: pending.scan,
      );
      if (context.mounted) {
        if (ok) {
          onPromoted?.call();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${pending.agentName} promoted to C2.')),
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
        final authResult = await ref.read(deviceAuthServiceProvider).authenticate(
              reason: 'Authenticate to promote ${pending.agentName} to Verified',
            );
        if (!authResult.success) {
          // Keep dialog open; caller shows inline error via return value.
          return authResult.errorMessage ??
              'Authentication cancelled or failed. Agent stays at C4.';
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
              content: Text(ok
                  ? '${pending.agentName} force-promoted to C2.'
                  : 'Promotion failed.'),
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
      title: const Text('Due Diligence Warning', style: TextStyle(color: Colors.amber)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${pending.agentName} was flagged:',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...pending.scan.findings.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $f', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                )),
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
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
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
          child: const Text('KEEP AT C4'),
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

class AmbientHubScreen extends StatefulWidget {
  const AmbientHubScreen({super.key});
  @override
  State<AmbientHubScreen> createState() => _AmbientHubScreenState();
}

class _AmbientHubScreenState extends State<AmbientHubScreen> {
  final PageController _pageController = PageController(initialPage: 1);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                onPressed: () => _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.ease),
              ),
              IconButton(
                icon: const Icon(Icons.mic, color: Colors.white54),
                onPressed: () => _pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.ease),
              ),
              IconButton(
                icon: const Icon(Icons.extension, color: Colors.white54),
                onPressed: () => _pageController.animateToPage(2, duration: const Duration(milliseconds: 300), curve: Curves.ease),
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
  ConsumerState<_PromotionDialogHost> createState() => _PromotionDialogHostState();
}

class _PromotionDialogHostState extends ConsumerState<_PromotionDialogHost> {
  int _lastHandledPromotionId = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<AgentVerificationService>(agentVerificationProvider, (prev, next) {
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

class _CommandCenterPageState extends ConsumerState<_CommandCenterPage> with TickerProviderStateMixin {
  late AnimationController _bCtrl;
  late Animation<double> _bOpacity;
  final _simulatorCtrl = TextEditingController();
  bool _simulatorBusy = false;

  @override
  void initState() {
    super.initState();
    _bCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    _bOpacity = Tween<double>(begin: 0.1, end: 0.4).animate(CurvedAnimation(parent: _bCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _bCtrl.dispose();
    _simulatorCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSimulator() async {
    final text = _simulatorCtrl.text.trim();
    if (text.isEmpty || _simulatorBusy) return;
    setState(() => _simulatorBusy = true);
    try {
      await ref.read(voiceHandshakeProvider).processVoiceCommand(text);
    } finally {
      if (mounted) setState(() => _simulatorBusy = false);
    }
  }

  IconData _getAudioIcon(String source) {
    if (source.toLowerCase().contains("bluetooth")) return Icons.bluetooth_audio;
    if (source.toLowerCase().contains("headset") || source.toLowerCase().contains("headphones")) return Icons.headphones;
    return Icons.speaker;
  }

  @override
  Widget build(BuildContext context) {
    final eng = ref.watch(voiceHandshakeProvider);
    final byok = ref.watch(byokServiceProvider);
    final server = ref.watch(localServerProvider);
    final session = ref.watch(conversationalSessionProvider);

    return SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([eng, byok, server]),
        builder: (context, _) {
          final isListening = eng.state == VoiceState.listening || eng.state == VoiceState.processing;
          final sessionLabel = session.isActive
              ? (session.kind == SessionKind.author ? 'AUTHOR SESSION' : 'REFINE SESSION')
              : null;
          return Column(
        children: [
          // Audio & System Status Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Icon(_getAudioIcon(eng.audioSource), color: Colors.grey, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          eng.audioSource.toUpperCase(),
                          style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: 'Courier', fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 12),
                        Icon(Icons.dns, color: server.isRunning ? Colors.green : Colors.red, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'EDGE ${server.statusLabel}',
                          style: TextStyle(
                            color: server.isRunning ? Colors.green : Colors.red,
                            fontSize: 10,
                            fontFamily: 'Courier',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (server.isRunning) ...[
                          const SizedBox(width: 6),
                          Text(
                            server.lanIp != null
                                ? '${server.lanIp}:${server.port}'
                                : 'localhost:${server.port}',
                            style: TextStyle(
                              color: server.lanIp != null ? Colors.green : Colors.white38,
                              fontSize: 10,
                              fontFamily: 'Courier',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  byok.hasApiKey ? 'KEY ACTIVE' : 'KEY REQ',
                  style: TextStyle(color: byok.hasApiKey ? Colors.green : Colors.amber, fontSize: 10, fontFamily: 'Courier', fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          if (sessionLabel != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, color: Colors.amber, size: 14),
                  const SizedBox(width: 6),
                  Text(sessionLabel,
                      style: const TextStyle(color: Colors.amber, fontSize: 10, fontFamily: 'Courier', fontWeight: FontWeight.bold)),
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
                            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                          ),
                          builder: (_) => const _AuthoringPanelSheet(),
                        );
                      },
                      child: const Text('OPEN AUTHORING',
                          style: TextStyle(color: Colors.greenAccent, fontSize: 10)),
                    ),
                  TextButton(
                    onPressed: () {
                      session.cancel();
                      eng.speak('Session cancelled.');
                    },
                    child: const Text('CANCEL', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ),
                ],
              ),
            ),
          
          // Log Panel (Scrollable)
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: eng.sessionLogs.isEmpty
                  ? const Center(child: Text("Waiting for handshake...", style: TextStyle(color: Colors.white30, fontSize: 12, fontStyle: FontStyle.italic)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      reverse: true, // newest logs at bottom (wait, if we reverse, and list is inserted at 0, 0 is at bottom)
                      itemCount: eng.sessionLogs.length,
                      separatorBuilder: (c, i) => const Divider(color: Colors.white10, height: 16),
                      itemBuilder: (context, index) {
                        final log = eng.sessionLogs[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(log.title.toUpperCase(), style: TextStyle(color: log.isError ? Colors.redAccent : Colors.greenAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                                Text(DateFormat('HH:mm:ss').format(log.timestamp), style: const TextStyle(color: Colors.white30, fontSize: 8)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(log.message, style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'Courier')),
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
                          ? [const Color(0xFF444444), const Color(0xFF222222)]
                          : [Colors.white.withValues(alpha: _bOpacity.value), Colors.transparent],
                    ),
                    boxShadow: isListening ? [const BoxShadow(color: Colors.white24, blurRadius: 20, spreadRadius: 2)] : null,
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
          
          Text(eng.micStatusMessage, style: const TextStyle(color: Colors.white54, fontSize: 10)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _simulatorCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Test simulator — e.g. Build me an agent that...',
                      hintStyle: TextStyle(color: Colors.white24, fontSize: 11),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _runSimulator(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _simulatorBusy ? null : _runSimulator,
                  icon: _simulatorBusy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send, color: Colors.greenAccent),
                ),
              ],
            ),
          ),
            const SizedBox(height: 12),
          ],
        );
      }),
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
  String _provider = "Google Gemini";
  bool _obscure = true;
  String _gender = "Male";
  bool _isGeneratingTTS = false;

  final Map<String, TextEditingController> _externalKeyCtrls = {
    for (final p in ExternalPlatform.values) p.name: TextEditingController(),
  };
  
  double _maxRecSecs = 10;
  String _responseMode = "Spoken Word";
  bool _vibrate = false;

  @override
  void initState() {
    super.initState();
    final byok = ref.read(byokServiceProvider);
    _keyCtrl.text = byok.apiKey;
    _modCtrl.text = byok.modelName;
    _urlCtrl.text = byok.customUrl;
    _provider = byok.apiProvider;
    _maxRecSecs = byok.maxRecordingSeconds.toDouble();
    _responseMode = byok.responseMode;
    _vibrate = byok.vibrateOnWake;
    for (final platform in ExternalPlatform.values) {
      _externalKeyCtrls[platform.name]?.text =
          byok.externalKeyFor(platform);
    }
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modCtrl.dispose();
    _urlCtrl.dispose();
    _respWordCtrl.dispose();
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
    final success = await ref.read(llmServiceProvider).generateAndSaveResponseAudio(
      _respWordCtrl.text.trim(), 'en-IN', _gender
    );
    setState(() => _isGeneratingTTS = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? "LLM Voice Generated & Saved!" : "LLM Voice Gen Failed (Check API Provider support)"))
      );
    }
  }

  void _save() async {
    final externalKeys = <String, String>{};
    for (final platform in ExternalPlatform.values) {
      final value = _externalKeyCtrls[platform.name]?.text.trim() ?? '';
      if (value.isNotEmpty) externalKeys[platform.name] = value;
    }
    await ref.read(byokServiceProvider).updateConfig(
      provider: _provider,
      apiKey: _keyCtrl.text.trim(),
      modelName: _modCtrl.text.trim(),
      customUrl: _urlCtrl.text.trim(),
      maxRecordingSeconds: _maxRecSecs.toInt(),
      responseMode: _responseMode,
      vibrateOnWake: _vibrate,
      externalPlatformKeys: externalKeys,
    );
    if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Credentials Saved")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("SOVEREIGN VAULT & SETTINGS", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
            const Divider(color: Colors.white12, height: 30),
            const _EdgeServerPanel(),
            const Divider(color: Colors.white12, height: 30),
            const Text("VAULT SECURITY", style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Force-promoting flagged agents uses your device screen lock, PIN, or fingerprint — the same gate as your banking apps. No separate vault password is required.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const Divider(color: Colors.white12, height: 30),
            const Text(
              'VOICE & LANGUAGE',
              style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'English only (Arch v3.7). Commands and agent authoring replies are in English.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _provider, dropdownColor: const Color(0xFF1E1E1E),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(labelText: "API Provider", labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
              items: LlmProviderFactory.providerIds
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _provider = val;
                    _modCtrl.text = LlmProviderFactory.defaultModelFor(val);
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keyCtrl, obscureText: _obscure,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: "API Key", labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, color: Colors.white30, size: 16), onPressed: () => setState(() => _obscure = !_obscure)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(controller: _modCtrl, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: const InputDecoration(labelText: "Model Name", labelStyle: TextStyle(color: Colors.white54, fontSize: 12))),
            if (LlmProviderFactory.requiresCustomUrl(_provider)) ...[
              const SizedBox(height: 16),
              TextField(controller: _urlCtrl, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: const InputDecoration(labelText: "Endpoint URL", labelStyle: TextStyle(color: Colors.white54, fontSize: 12))),
            ],
            const SizedBox(height: 24),
            const Text(
              'EXTERNAL PLATFORM KEYS (user-authorized egress)',
              style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Agents that post to Twitter/X, Facebook, Instagram, YouTube, Threads, or a webhook need keys here. Promotion to Verified (C2) is required before external posting.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 12),
            for (final platform in ExternalPlatform.values) ...[
              TextField(
                controller: _externalKeyCtrls[platform.name],
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: platform.label,
                  labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
            const Text("BEHAVIOR SETTINGS", style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text("Max Recording Duration:", style: TextStyle(color: Colors.white, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: _maxRecSecs,
                    min: 7, max: 15, divisions: 8,
                    label: "${_maxRecSecs.toInt()}s",
                    activeColor: Colors.greenAccent,
                    onChanged: (val) => setState(() => _maxRecSecs = val),
                  ),
                ),
                Text("${_maxRecSecs.toInt()}s", style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: _responseMode, dropdownColor: const Color(0xFF1E1E1E),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(labelText: "Wake Response Mode", labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
              items: ["Spoken Word", "System Sound", "Silent"].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
              onChanged: (val) { if (val != null) setState(() => _responseMode = val); },
            ),
            SwitchListTile(
              title: const Text("Vibrate on Wake", style: TextStyle(color: Colors.white, fontSize: 13)),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: Colors.greenAccent,
              value: _vibrate,
              onChanged: (val) => setState(() => _vibrate = val),
            ),
            
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
              onPressed: _save, child: const Text("SAVE CREDENTIALS & SETTINGS", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            const Divider(color: Colors.white12, height: 40),
            const Text("AI VOICE RESPONSE GENERATOR", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
            const SizedBox(height: 16),
            TextField(controller: _respWordCtrl, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: const InputDecoration(labelText: "Response Word", labelStyle: TextStyle(color: Colors.white54, fontSize: 12))),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _gender, dropdownColor: const Color(0xFF1E1E1E),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(labelText: "Voice Gender", labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
              items: ["Male", "Female"].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
              onChanged: (val) { if (val != null) setState(() => _gender = val); },
            ),
            const SizedBox(height: 16),
            if (!_selectedProviderSupportsTts)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'LLM voice generation requires OpenAI or Custom OpenAI (TTS not supported by this provider).',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF222222), foregroundColor: Colors.greenAccent, padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: (_isGeneratingTTS || !_selectedProviderSupportsTts) ? null : _generateLLMVoice,
              icon: _isGeneratingTTS ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome, size: 18),
              label: Text(_isGeneratingTTS ? "GENERATING..." : "GENERATE VOICE VIA LLM", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            const Divider(color: Colors.white12, height: 40),
            const _VoiceTrainingStudio(),
          ],
        ),
      ),
    );
  }
}

class _EdgeServerPanel extends ConsumerWidget {
  const _EdgeServerPanel();

  Future<void> _copyToClipboard(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(localServerProvider);

    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final statusColor = server.isRunning ? Colors.greenAccent : Colors.redAccent;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'LOCAL EDGE SERVER',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
            const SizedBox(height: 12),
            _edgeInfoRow('Status', server.statusLabel, valueColor: statusColor),
            _edgeInfoRow('Host', server.host),
            _edgeInfoRow('Port', server.isRunning ? '${server.port}' : '${LocalServerService.defaultPort} (not bound)'),
            _edgeInfoRow('On device', server.isRunning ? server.localhostAddress : 'Offline'),
            if (server.isRunning && server.lanIp != null)
              _edgeInfoRow('LAN (Wi-Fi)', server.lanServerAddress, valueColor: Colors.greenAccent),
            if (server.isRunning && server.lanIp == null)
              _edgeInfoRow('LAN (Wi-Fi)', 'Unavailable — use on-device localhost', valueColor: Colors.amber),
            const SizedBox(height: 8),
            const Text('Registered endpoints', style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 4),
            ...LocalServerService.coreEndpoints.map(
              (ep) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(ep, style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'Courier')),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                    onPressed: server.isRunning
                        ? () => _copyToClipboard(context, server.statusUrl, 'Status URL')
                        : null,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('COPY STATUS URL', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.greenAccent, side: const BorderSide(color: Colors.greenAccent)),
                    onPressed: server.isRunning
                        ? () => launchInBrowser(context, server.statusUrl)
                        : null,
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text('OPEN STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
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
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor ?? Colors.white, fontSize: 12, fontFamily: 'Courier'),
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
          path: '${dir.path}/custom_response.m4a'
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
          path: '${dir.path}/wakeword_sample_$_wakeWordCount.m4a'
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
        const Text("VOICE TRAINING STUDIO", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 8),
        const Text("Record your custom response (e.g. 'Haan Bhai') and collect wake word samples to build an offline model later.", style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 16),
        if (_status.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_status, style: const TextStyle(color: Colors.amber, fontSize: 12, fontStyle: FontStyle.italic))),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: _isRecordingResponse ? Colors.red : const Color(0xFF333333), padding: const EdgeInsets.symmetric(vertical: 12)),
                onPressed: _toggleResponse,
                icon: Icon(_isRecordingResponse ? Icons.stop : Icons.mic, size: 18),
                label: const Text("CUSTOM RESPONSE", style: TextStyle(fontSize: 10), textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: _isRecordingWakeWord ? Colors.red : const Color(0xFF333333), padding: const EdgeInsets.symmetric(vertical: 12)),
                onPressed: _toggleWakeWord,
                icon: Icon(_isRecordingWakeWord ? Icons.stop : Icons.mic, size: 18),
                label: Text("WAKE WORD LOG ($_wakeWordCount)", style: const TextStyle(fontSize: 10), textAlign: TextAlign.center),
              ),
            ),
          ],
        )
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

    return DefaultTabController(
      length: 4,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("BHAI LOG",
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onPressed: () => _openAuthoringSheet(context, ref),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text("CREATE BRO CODE", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            const _VaultDashboardsBanner(),
            const TabBar(
              isScrollable: true,
              indicatorColor: Colors.greenAccent,
              labelColor: Colors.greenAccent,
              unselectedLabelColor: Colors.white54,
              tabs: [
                Tab(text: "C1: CORE"),
                Tab(text: "C2: VERIFIED"),
                Tab(text: "C3: DUE DILIGENCE"),
                Tab(text: "C4: UNVERIFIED"),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: AgentSecurityClass.values
                    .map((c) => _buildAgentGrid(context, ref, grouped[c]!))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentGrid(BuildContext context, WidgetRef ref, List<AurBhaiAgent> agents) {
    if (agents.isEmpty) {
      return const Center(child: Text("No agents in this trust tier.", style: TextStyle(color: Colors.white30)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.8,
      ),
      itemCount: agents.length,
      itemBuilder: (context, index) {
        final a = agents[index];
        final isJs = a is JsAgentAdapter;
        final builtAt = isJs ? (a.updatedAt ?? a.createdAt) : null;
        return GestureDetector(
          onTap: () => _openAgentDetail(context, ref, a),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(isJs ? Icons.javascript : Icons.extension,
                    color: isJs ? Colors.amberAccent : Colors.greenAccent, size: 32),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(a.name,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(height: 4),
                Text(isJs ? "JS AGENT" : "NATIVE",
                    style: const TextStyle(color: Colors.white38, fontSize: 8, letterSpacing: 1)),
                if (builtAt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    DateFormat('MMM d, HH:mm').format(builtAt.toLocal()),
                    style: const TextStyle(color: Colors.white24, fontSize: 7),
                    textAlign: TextAlign.center,
                  ),
                ],
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AgentAuthoringSheet(),
    );
  }

  void _openAgentDetail(BuildContext context, WidgetRef ref, AurBhaiAgent agent) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AgentDetailSheet(agent: agent),
    );
  }
}

/// Surfaces user-created HTML dashboards stored in the sovereign vault
/// (MS-TELEMETRY-DASHBOARD-UX1). Shows a same-origin URL + Open in Browser.
class _VaultDashboardsBanner extends ConsumerStatefulWidget {
  const _VaultDashboardsBanner();
  @override
  ConsumerState<_VaultDashboardsBanner> createState() => _VaultDashboardsBannerState();
}

class _VaultDashboardsBannerState extends ConsumerState<_VaultDashboardsBanner> {
  late Future<List<Map<String, String>>> _future;
  int _lastTick = 0;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, String>>> _load() {
    return ref.read(telemetryBusProvider).listVaultEntries(mimeType: 'text/html');
  }

  void _refresh() => setState(() => _future = _load());

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
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("VAULT DASHBOARDS",
                      style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.refresh, color: Colors.white38, size: 16),
                    onPressed: _refresh,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (dashboards.isEmpty)
                const Text("No dashboards yet. Create an agent that builds one, then run it.",
                    style: TextStyle(color: Colors.white30, fontSize: 11, fontStyle: FontStyle.italic))
              else
                ...dashboards.map((d) {
                  final key = d['key']!;
                  final url = server.isRunning ? server.vaultUrl(key) : 'Server offline';
                  final localUrl = server.isRunning ? '${server.localhostAddress}/vault/$key' : null;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(key, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                              Text(
                                server.lanIp != null ? 'LAN: $url' : url,
                                style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontFamily: 'Courier'),
                              ),
                              if (localUrl != null && server.lanIp != null)
                                Text('On phone: $localUrl',
                                    style: const TextStyle(color: Colors.white38, fontSize: 8, fontFamily: 'Courier')),
                            ],
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.copy, color: Colors.white38, size: 16),
                          onPressed: server.isRunning
                              ? () async {
                                  await Clipboard.setData(ClipboardData(text: url));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dashboard URL copied')));
                                  }
                                }
                              : null,
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.open_in_browser, color: Colors.greenAccent, size: 18),
                          onPressed: server.isRunning ? () => launchInBrowser(context, url) : null,
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}

/// MS-USER-ECOSYSTEM-UX1: Create-with-AI (Path A) + Manual Import (Path B).
class _AgentAuthoringSheet extends ConsumerStatefulWidget {
  const _AgentAuthoringSheet();
  @override
  ConsumerState<_AgentAuthoringSheet> createState() => _AgentAuthoringSheetState();
}

class _AgentAuthoringSheetState extends ConsumerState<_AgentAuthoringSheet> {
  bool _aiMode = true;
  bool _busy = false;
  String? _error;

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
      final draft = await ref.read(llmServiceProvider).authorAgent(_promptCtrl.text.trim());
      _nameCtrl.text = draft.name;
      _descCtrl.text = draft.description;
      _scriptCtrl.text = draft.script;
      _schemaCtrl.text = draft.inputSchema.isEmpty ? '' : const JsonEncoder.withIndent('  ').convert(draft.inputSchema);
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

      await ref.read(jsAgentRegistryProvider).saveAndRegisterAgent(
            name: name,
            description: _descCtrl.text.trim().isEmpty ? 'User-created agent.' : _descCtrl.text.trim(),
            inputSchema: schema,
            script: script,
            securityClass: AgentSecurityClass.c4Unverified,
          );
      if (mounted) {
        Navigator.of(context).pop();
        if (scan.passed) {
          verification.requestPromotion(agentName: name, scan: scan);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Agent "$name" registered at C4. Due diligence passed — promote when ready.')),
          );
        } else {
          verification.requestPromotion(agentName: name, scan: scan);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Agent "$name" registered at C4 with due-diligence flags.')),
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
            const Text("INTRODUCE BRO CODE TO BHAI LOG",
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1)),
            const SizedBox(height: 12),
            Row(
              children: [
                _modeChip("AI AUTHORING", _aiMode, () => setState(() => _aiMode = true)),
                const SizedBox(width: 8),
                _modeChip("MANUAL IMPORT", !_aiMode, () => setState(() => _aiMode = false)),
              ],
            ),
            const SizedBox(height: 16),
            if (_aiMode) ...[
              TextField(
                controller: _promptCtrl,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Create an agent that... (e.g. "builds a live telemetry dashboard showing accelerometer over time")',
                  hintStyle: TextStyle(color: Colors.white24, fontSize: 12),
                  labelText: 'Describe the agent',
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF222222), foregroundColor: Colors.greenAccent, padding: const EdgeInsets.symmetric(vertical: 12)),
                onPressed: _busy ? null : _generate,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(_busy ? "GENERATING..." : "GENERATE WITH AI", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              const Divider(color: Colors.white12, height: 28),
            ],
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Agent Name (PascalCase)', labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(labelText: 'Description', labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _scriptCtrl,
              maxLines: 8,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'Courier'),
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
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'Courier'),
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
              decoration: const InputDecoration(labelText: 'Security Class', labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
              items: AgentSecurityClass.values
                  .map((c) => DropdownMenuItem(value: c, child: Text(c.label)))
                  .toList(),
              onChanged: (val) { if (val != null) setState(() => _securityClass = val); },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _busy ? null : _save,
              child: const Text("SAVE & REGISTER AGENT", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
            color: selected ? Colors.greenAccent.withValues(alpha: 0.15) : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? Colors.greenAccent : Colors.white12),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(color: selected ? Colors.greenAccent : Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}

/// Agent detail + lifecycle (run / improve / export / delete) — MS-USER-ECOSYSTEM-ENG2.
class _AgentDetailSheet extends ConsumerStatefulWidget {
  final AurBhaiAgent agent;
  const _AgentDetailSheet({required this.agent});
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_scanLoaded) {
      _scanLoaded = true;
      _refreshScan();
    }
  }

  void _refreshScan() {
    if (widget.agent is JsAgentAdapter) {
      _scan = ref
          .read(agentVerificationProvider)
          .scanScript((widget.agent as JsAgentAdapter).script);
    }
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
            'Promote to C2 Verified before running against the real vault. Use TEST IN SANDBOX or IMPROVE first.';
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
        result = await (widget.agent as JsAgentAdapter)
            .executeInSandbox(const {});
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
        // Sandbox HTML never lives in the sovereign vault / edge server.
        if (!sandbox && !isError && keys.isNotEmpty) {
          matchedKey = keys.last;
        }
      }

      if (!isError &&
          (result.toLowerCase().contains('error') ||
              result.toLowerCase().contains('syntaxerror'))) {
        isError = true;
      }

      setState(() {
        _runResult = sandbox
            ? '[SANDBOX] $result'
            : result;
        _runWasError = isError;
        _dashboardKey = matchedKey;
        _dashboardUrl = (matchedKey != null && server.isRunning)
            ? server.vaultUrl(matchedKey)
            : null;
      });
      if (matchedKey != null) {
        ref.read(vaultDashboardRefreshProvider).bump();
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
          const SnackBar(content: Text('Agent bundle copied to clipboard')));
    }
  }

  Future<void> _delete() async {
    await ref.read(jsAgentRegistryProvider).deleteAgent(widget.agent.name);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Agent "${widget.agent.name}" removed')));
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
        dueDiligenceFindings: _scan?.findings ?? const [],
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
          16, 16, 16, mq.viewInsets.bottom + mq.padding.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(isJs ? Icons.javascript : Icons.extension,
                    color:
                        isJs ? Colors.amberAccent : Colors.greenAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(agent.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: const Color(0xFF222222),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(isJs ? agent.securityClass.id : 'C2',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(agent.description,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            if (builtAt != null) ...[
              const SizedBox(height: 6),
              Text(
                'Built ${DateFormat('yyyy-MM-dd HH:mm').format(builtAt.toLocal())}',
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontFamily: 'Courier'),
              ),
            ],
            if (isJs) ...[
              const SizedBox(height: 10),
              _buildVerificationBanner(agent, scan),
            ],
            const SizedBox(height: 12),
            if (agent.inputSchema.isNotEmpty) ...[
              const Text("INPUT SCHEMA",
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 4),
              ...agent.inputSchema.entries.map((e) => Text(
                    "• ${e.key} (${e.value.type})${e.value.required ? '' : ' — optional'}: ${e.value.description}",
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11),
                  )),
              const SizedBox(height: 12),
            ],
            if (isJs) ...[
              const Text("SOURCE",
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: const Color(0xFF0D0D0D),
                    borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  child: Text(agent.script,
                      style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 10,
                          fontFamily: 'Courier')),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_runResult != null) ...[
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
                          color: Colors.redAccent.withValues(alpha: 0.4))
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
                  icon: const Icon(Icons.tune,
                      color: Colors.lightBlueAccent, size: 16),
                  label: const Text(
                    'FIX WITH IMPROVE',
                    style: TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
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
                      launchInBrowser(context, _dashboardUrl!),
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: Text(
                    'OPEN DASHBOARD (${_dashboardKey ?? ''})',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: _dashboardUrl!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied: $_dashboardUrl')),
                      );
                    }
                  },
                  child: Text(
                    _dashboardUrl!,
                    style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontFamily: 'Courier'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],
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
                        vertical: 12, horizontal: 12),
                  ),
                  onPressed: (_running || !canRun) ? null : () => _run(),
                  icon: _running
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(
                          canRun ? Icons.play_arrow : Icons.lock,
                          size: 18,
                        ),
                  label: Text(
                    _running
                        ? 'RUNNING'
                        : (canRun ? 'RUN' : 'RUN (C2 ONLY)'),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                if (isJs)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orangeAccent,
                      side: const BorderSide(color: Colors.orangeAccent),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                    ),
                    onPressed: _running ? null : () => _run(sandbox: true),
                    icon: const Icon(Icons.science, size: 16),
                    label: const Text('TEST IN SANDBOX',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                if (isJs)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      side: const BorderSide(color: Colors.lightBlueAccent),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                    ),
                    onPressed: _openImprove,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('IMPROVE',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                if (isJs &&
                    agent.securityClass != AgentSecurityClass.c2Verified)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amber,
                      side: const BorderSide(color: Colors.amber),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                    ),
                    onPressed: _promote,
                    icon: const Icon(Icons.verified_user, size: 16),
                    label: const Text('PROMOTE',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                if (isJs)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                    ),
                    onPressed: _export,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('EXPORT',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                if (isJs)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 12),
                    ),
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('DELETE',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationBanner(
      JsAgentAdapter agent, DueDiligenceResult? scan) {
    final flagged = scan != null && scan.flagged;
    final atC2 = agent.securityClass == AgentSecurityClass.c2Verified;
    String text;
    Color color;
    if (atC2) {
      text = 'Verified (C2) — RUN enabled.';
      color = Colors.greenAccent;
    } else if (flagged) {
      text =
          'Due diligence: FLAGGED — fix via IMPROVE before promotion. RUN disabled until C2.';
      color = Colors.amber;
    } else {
      text =
          'Due diligence passed. Promote to C2 to enable RUN.';
      color = Colors.lightBlueAccent;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(color: color, fontSize: 11)),
          if (flagged)
            ...scan.findings.map((f) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('• $f',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 10)),
                )),
        ],
      ),
    );
  }
}

/// Live visual authoring checklist + BUILD gate.
class _AuthoringPanelSheet extends ConsumerStatefulWidget {
  const _AuthoringPanelSheet();
  @override
  ConsumerState<_AuthoringPanelSheet> createState() => _AuthoringPanelSheetState();
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
    final canBuild = spec.purpose.hasValue &&
        spec.behaviorResponse.hasValue &&
        (session.isInReview || spec.allRelevantConfirmed);
    final scan = session.lastScan;
    final mq = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, mq.viewInsets.bottom + mq.padding.bottom + 16),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('REVIEW',
                        style: TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
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
            const Text('FINAL REVIEW',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
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
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
    final editable = slot != AppSpecSlot.parameters &&
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
                  child: const Text('SAVE', style: TextStyle(color: Colors.greenAccent)),
                ),
                TextButton(
                  onPressed: () => setState(() => _editingSlot = null),
                  child: const Text('CANCEL', style: TextStyle(color: Colors.white38)),
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
  final _progressScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final chips = _suggestedChips();
    if (chips.isNotEmpty) {
      _changeCtrl.text = chips.first;
    }
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
    setState(() {
      _busy = true;
      _error = null;
      _draft = null;
      _verified = false;
      if (!isRetry) {
        _progressLog.clear();
        _attempt = 0;
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

      final workspace = BroCodeWorkspace(
        name: widget.agent.name,
        description: widget.agent.description,
        inputSchema: widget.agent.inputSchema.map(
          (k, v) => MapEntry(k, v.toJson()),
        ),
        script: widget.agent.script,
        assets: assets,
      );

      _appendProgress('Handing off to coding agent (tools + observe + retry)…');

      final result = await ref.read(broCodeCodingAgentProvider).improve(
            workspace: workspace,
            changeRequest: _changeCtrl.text.trim(),
            lastRunError: widget.lastRunError,
            dueDiligenceFindings: widget.dueDiligenceFindings,
            priorFailureContext: isRetry ? _lastFailureForRetry : null,
            onProgress: _appendProgress,
            onContextUpdate: _onContextUpdate,
          );

      setState(() {
        _draft = result.draft;
        _verified = result.verified;
        _contextUsed = result.estimatedTokensUsed;
        _contextBudget = result.contextBudgetTokens;
        _lastTurnsUsed = result.turnsUsed;
      });

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
      final friendly =
          e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      _lastFailureForRetry = friendly;
      _appendProgress('Failed: $friendly');
      setState(() => _error = friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendToTestCases() async {
    final registry = ref.read(jsAgentRegistryProvider);
    final assets = await registry.readAgentAssets(widget.agent.name);
    final workspace = BroCodeWorkspace(
      name: widget.agent.name,
      description: widget.agent.description,
      inputSchema: widget.agent.inputSchema.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
      script: _draft?.script ?? widget.agent.script,
      assets: assets,
    );

    final report = BroCodeFixtureReport(
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
    );

    await Clipboard.setData(ClipboardData(text: report.toJsonString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Fixture report copied. Save as test/fixtures/bro_code/<name>.bundle.json on your dev machine, then run flutter test.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
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
                  ? '${widget.agent.name} updated — due diligence passed. Promote to C2 to enable RUN.'
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
          16, 16, 16, mq.viewInsets.bottom + mq.padding.bottom + 16),
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
              const Text('SUGGESTED FEEDBACK',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
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
                        labelStyle:
                            const TextStyle(color: Colors.lightBlueAccent),
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
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 11),
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
                    const Text('Due diligence findings:',
                        style: TextStyle(color: Colors.amber, fontSize: 11)),
                    ...widget.dueDiligenceFindings.map((f) => Text('• $f',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11))),
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
                    fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
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
                  const Text('AGENT ACTIVITY',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                  const Spacer(),
                  if (_contextUsed > 0)
                    Text(
                      'Est. $_contextUsed / $_contextBudget',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 9),
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
                          color: isHeartbeat
                              ? Colors.white38
                              : Colors.white70,
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
              const Text('VERIFIED DRAFT',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
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
                  _busy ? 'APPLYING…' : 'APPLY TO VAULT (C4)',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
            if (_error != null || (!_verified && _progressLog.isNotEmpty && !_busy)) ...[
              const SizedBox(height: 12),
              if (_error != null)
                Text(_error!,
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 11)),
              const SizedBox(height: 8),
              const Text(
                'Improvement did not succeed yet. Retry, or send this Bro Code to test cases so we can fix the agent in a future update.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _sendToTestCases,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.amberAccent,
                  side: const BorderSide(color: Colors.amberAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.science_outlined, size: 18),
                label: const Text('SEND TO TEST CASES',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed:
                    _busy ? null : () => _generatePatch(isRetry: true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  side: const BorderSide(color: Colors.lightBlueAccent),
                ),
                child: const Text('RETRY AGENT',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
