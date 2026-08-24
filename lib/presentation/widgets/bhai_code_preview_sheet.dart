import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agents/agent_base.dart';
import '../../core/agents/js_agent_adapter.dart';
import '../../core/services/agent_verification_service.dart';
import '../../core/services/circle_registry_service.dart';
import '../../core/services/js_agent_registry.dart';
import '../../core/services/js_bridge_service.dart';
import '../../core/services/marketplace_catalog.dart';
import '../../core/services/sandbox_queue_service.dart';
import 'due_diligence_findings_list.dart';

/// Pre-pickup / preview sheet for Sabke Bhai & Friend Circle listings.
class BhaiCodePreviewSheet extends ConsumerStatefulWidget {
  final MarketplaceListing listing;
  final bool showPickup;
  final VoidCallback? onInstalled;
  final Future<bool> Function(MarketplaceListing listing)? customPickup;

  const BhaiCodePreviewSheet({
    super.key,
    required this.listing,
    this.showPickup = true,
    this.onInstalled,
    this.customPickup,
  });

  static Future<void> open(
    BuildContext context, {
    required MarketplaceListing listing,
    bool showPickup = true,
    VoidCallback? onInstalled,
    Future<bool> Function(MarketplaceListing listing)? customPickup,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => BhaiCodePreviewSheet(
        listing: listing,
        showPickup: showPickup,
        onInstalled: onInstalled,
        customPickup: customPickup,
      ),
    );
  }

  @override
  ConsumerState<BhaiCodePreviewSheet> createState() =>
      _BhaiCodePreviewSheetState();
}

class _BhaiCodePreviewSheetState extends ConsumerState<BhaiCodePreviewSheet> {
  DueDiligenceResult? _scan;
  String? _busyAction;
  String? _sandboxResult;
  final _paramCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Only auto-run due diligence if the agent is already installed (Mere Bhai).
    if (!widget.showPickup) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runScan());
    }
  }

  @override
  void dispose() {
    _paramCtrl.dispose();
    super.dispose();
  }

  Future<void> _runScan({bool isManualUserTap = false}) async {
    if (!widget.listing.access.allowDiligence) {
      if (!mounted) return;
      setState(() => _scan = null);
      return;
    }
    if (isManualUserTap) {
      setState(() {
        _busyAction = 'scan';
        _scan = null;
      });
      await Future.delayed(const Duration(milliseconds: 350));
    }
    final content = await _loadListingContent(widget.listing);
    final scan = ref
        .read(agentVerificationProvider)
        .scanScript(content['script'] as String);
    if (!mounted) return;
    setState(() {
      _scan = scan;
      _busyAction = null;
    });
    if (isManualUserTap && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            scan.flagged
                ? 'Due diligence re-scan: Flagged (RED)'
                : (scan.findings.any((f) => f.severity == 'warning')
                    ? 'Due diligence re-scan: Caution (AMBER)'
                    : 'Due diligence re-scan: Passed (GREEN)'),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Color get _lightColor {
    if (!widget.listing.access.allowDiligence) return Colors.white38;
    final scan = _scan;
    if (scan == null) return Colors.white38;
    if (scan.flagged) return Colors.redAccent;
    final warnings = scan.findings
        .where((f) => f.severity == 'warning')
        .isNotEmpty;
    if (warnings) return Colors.amberAccent;
    return Colors.greenAccent;
  }

  String get _lightLabel {
    if (!widget.listing.access.allowDiligence) {
      return 'Due diligence: disabled by creator';
    }
    final scan = _scan;
    if (scan == null) return 'Scanning…';
    if (scan.flagged) return 'Due diligence: RED — flagged';
    final warnings = scan.findings
        .where((f) => f.severity == 'warning')
        .isNotEmpty;
    if (warnings) return 'Due diligence: AMBER — caution';
    return 'Due diligence: GREEN — passed';
  }

  List<String> _permissionLines() {
    final lines = <String>[];
    // Note: For assetBundleDir, this will just show empty if not loaded yet,
    // but typically UI relies on static manifest. For a true fix, we'd make this async.
    final script = widget.listing.script;
    void add(String label, bool hit) {
      if (hit) lines.add(label);
    }

    add(
      'Vault read/write (System.writeVault / readVault)',
      script.contains('writeVault') || script.contains('readVault'),
    );
    add('SQL (System.querySQL)', script.contains('querySQL'));
    add(
      'Inbox (System.readInbox / consumeInbox)',
      script.contains('readInbox') || script.contains('consumeInbox'),
    );
    add(
      'Network / HTTP',
      RegExp(r'https?://|fetch\(|XMLHttpRequest').hasMatch(script),
    );
    add('DOM / document', RegExp(r'\bdocument\.|\bwindow\.').hasMatch(script));
    if (widget.listing.inputSchema.isNotEmpty) {
      lines.add('Inputs: ${widget.listing.inputSchema.keys.join(", ")}');
    }
    if (lines.isEmpty) {
      lines.add('No vault/network APIs detected in static scan.');
    }
    lines.add(
      widget.listing.access.shareModel
          ? 'Creator shares model: yes'
          : 'Creator shares model: no',
    );
    return lines;
  }

  Future<Map<String, dynamic>> _loadListingContent(MarketplaceListing listing) async {
    var finalScript = listing.script;
    var finalAssets = Map<String, String>.from(listing.vaultAssets);
    if (listing.assetBundleDir != null) {
      try {
        final bundle = DefaultAssetBundle.of(context);
        final scriptJs = await bundle.loadString('${listing.assetBundleDir}/script.js');
        final dashboardHtml = await bundle.loadString('${listing.assetBundleDir}/dashboard.html');
        finalScript = scriptJs;
        finalAssets['telemeter.html'] = dashboardHtml;
        finalAssets['dashboard.html'] = dashboardHtml;
      } catch (e) {
        debugPrint('Error loading preview bundle: $e');
      }
    }
    return {
      'script': finalScript,
      'assets': finalAssets,
    };
  }

  Future<void> _testNow() async {
    if (!widget.listing.access.allowSandboxTest) return;
    setState(() {
      _busyAction = 'testNow';
      _sandboxResult = null;
    });
    try {
      final params = <String, dynamic>{};
      final raw = _paramCtrl.text.trim();
      if (raw.isNotEmpty) {
        // Simple key=value lines or a single free-text "query" param.
        if (raw.contains('=')) {
          for (final line in raw.split(RegExp(r'[\n,]'))) {
            final parts = line.split('=');
            if (parts.length >= 2) {
              params[parts.first.trim()] = parts.sublist(1).join('=').trim();
            }
          }
        } else if (widget.listing.inputSchema.isNotEmpty) {
          params[widget.listing.inputSchema.keys.first] = raw;
        } else {
          params['text'] = raw;
        }
      }
      final content = await _loadListingContent(widget.listing);
      final bridge = ref.read(jsBridgeServiceProvider);
      final result = await bridge.executeAgentScript(
        agentName: widget.listing.name,
        script: content['script'] as String,
        parameters: params,
        sandboxMode: true,
        assets: content['assets'] as Map<String, String>,
      );
      if (!mounted) return;
      setState(() {
        _sandboxResult =
            '[SANDBOX] ${result.isError ? "ERROR: " : ""}${result.message}';
      });
      await ref
          .read(sandboxQueueProvider)
          .setLastResult(widget.listing.id, _sandboxResult!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sandboxResult = '[SANDBOX] ERROR: $e');
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _testLater() async {
    await ref.read(sandboxQueueProvider).enqueue(widget.listing);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.listing.name} queued in Sandbox (test later)'),
      ),
    );
    Navigator.pop(context);
  }

  Future<void> _pickup() async {
    setState(() => _busyAction = 'pickup');
    try {
      final content = await _loadListingContent(widget.listing);
      // Enforce due diligence before installing
      if (widget.listing.access.allowDiligence) {
        final scan = ref.read(agentVerificationProvider).scanScript(content['script'] as String);
        if (scan.flagged) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Installation blocked: Due diligence failed (Flagged)'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }
      }

      final ok = widget.customPickup != null
          ? await widget.customPickup!(widget.listing)
          : await ref.read(marketplaceCatalogProvider).pickup(
                widget.listing,
                securityClass: AgentSecurityClass.c2Verified,
              );
      await ref.read(jsAgentRegistryProvider).loadAndRegisterAgents();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? '${widget.listing.name} passed due diligence and installed to Mere Bhai'
                : '${widget.listing.name} already installed',
          ),
        ),
      );
      if (ok) {
        widget.onInstalled?.call();
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Pick up failed: $e')));
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    final safePaddingBottom = MediaQuery.paddingOf(context).bottom;
    final bottomPadding = viewInsetsBottom > 0 ? viewInsetsBottom : safePaddingBottom;
    
    final author = listing.author.trim().isEmpty
        ? 'local pool'
        : listing.author;
    final desc = listing.description.trim().isEmpty
        ? 'No description'
        : listing.description;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomPadding),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              listing.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Creator: $author · ${listing.license}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'DESCRIPTION',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              desc,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (!widget.showPickup) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _lightColor.withValues(alpha: 0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.circle, size: 12, color: _lightColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _lightLabel,
                            style: TextStyle(
                              color: _lightColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (listing.access.allowDiligence)
                          TextButton(
                            onPressed:
                                _busyAction != null
                                    ? null
                                    : () => _runScan(isManualUserTap: true),
                            child: _busyAction == 'scan'
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Text(
                                    'RE-SCAN',
                                    style: TextStyle(fontSize: 11),
                                  ),
                          ),
                      ],
                    ),
                    if (_scan != null && _scan!.findings.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DueDiligenceFindingsList(scan: _scan!),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              'PERMISSIONS / VAULT ACCESS',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Declared / detected (static scan)',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
            const SizedBox(height: 6),
            ..._permissionLines().map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· ', style: TextStyle(color: Colors.white54)),
                    Expanded(
                      child: Text(
                        line,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (listing.access.allowSandboxTest) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _paramCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Sandbox input (optional)',
                  hintText: 'text… or key=value',
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                  hintStyle: TextStyle(color: Colors.white30, fontSize: 11),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Voice: use Command Center mic after Test now, or type above.',
                style: TextStyle(color: Colors.white30, fontSize: 10),
              ),
            ],
            if (_sandboxResult != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E1A12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.greenAccent.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  _sandboxResult!,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 11,
                    fontFamily: 'Courier',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showPickup)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _busyAction != null ? () {} : _pickup,
                    icon: _busyAction == 'pickup'
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download, size: 18),
                    label: const Text(
                      'INSTALL (MERE BHAI)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                if (widget.showPickup && listing.access.allowSandboxTest)
                  const SizedBox(height: 12),
                if (listing.access.allowSandboxTest)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlueAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _busyAction != null ? () {} : _testNow,
                    icon: _busyAction == 'testNow'
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.science, size: 18),
                    label: const Text(
                      'TEST NOW (SANDBOX)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                if (listing.access.allowSandboxTest)
                  const SizedBox(height: 12),
                if (listing.access.allowSandboxTest)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      side: const BorderSide(color: Colors.lightBlueAccent),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _busyAction != null ? () {} : _testLater,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: const Text('QUEUE IN SANDBOX', style: TextStyle(fontSize: 14)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Open preview for an already-installed agent (script from vault bundle).
Future<void> openInstalledBhaiPreview(
  BuildContext context,
  WidgetRef ref,
  AurBhaiAgent agent,
) async {
  String script = agent is JsAgentAdapter ? agent.script : '';
  Map<String, dynamic> schema = {
    for (final e in agent.inputSchema.entries)
      e.key: {'type': e.value.type, 'description': e.value.description},
  };
  String desc = agent.description;
  try {
    final bundle = await ref
        .read(jsAgentRegistryProvider)
        .exportAgentBundle(agent.name);
    if (bundle != null) {
      script = bundle['script'] as String? ?? script;
      final schemaMap = Map<String, dynamic>.from(
        (bundle['schema'] as Map?) ?? {},
      );
      desc = schemaMap['description'] as String? ?? desc;
      schema = Map<String, dynamic>.from(
        (schemaMap['inputSchema'] as Map?) ?? schema,
      );
    }
  } catch (_) {}

  if (!context.mounted) return;
  final listing = MarketplaceListing(
    id: 'installed:${agent.name}',
    name: agent.name,
    description: desc,
    script: script,
    inputSchema: schema,
    author: 'installed',
  );
  await BhaiCodePreviewSheet.open(context, listing: listing, showPickup: false);
}

/// Helper used by Friend Circle pickup path.
Future<bool> pickupCircleListing(WidgetRef ref, CircleListing listing) async {
  final ok = await ref.read(circleRegistryProvider).pickup(listing);
  await ref.read(jsAgentRegistryProvider).loadAndRegisterAgents();
  return ok;
}
