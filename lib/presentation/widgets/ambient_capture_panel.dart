import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/model_studio/ambient_capture_service.dart';

/// Confirm/reject Path L label candidates (MS-AMBIENT-CAPTURE-UX1).
class AmbientCapturePanel extends ConsumerStatefulWidget {
  final String? defaultAgentName;
  final bool showTitle;

  const AmbientCapturePanel({
    super.key,
    this.defaultAgentName,
    this.showTitle = true,
  });

  @override
  ConsumerState<AmbientCapturePanel> createState() =>
      _AmbientCapturePanelState();
}

class _AmbientCapturePanelState extends ConsumerState<AmbientCapturePanel> {
  final _labelCtrl = TextEditingController(text: 'positive');
  final _agentCtrl = TextEditingController();
  int _fineWindowSecs = 45;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _agentCtrl.text = widget.defaultAgentName ?? 'PathH';
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ambient = ref.read(ambientCaptureProvider);
      _fineWindowSecs = ambient.buffer.window.inSeconds.clamp(30, 60);
      await ambient.load();
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _agentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ambient = ref.watch(ambientCaptureProvider);
    final pending = ambient.pending;
    final bufLen = ambient.buffer.length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showTitle) ...[
            const Text(
              'MODEL STUDIO — AMBIENT CAPTURE',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            _loaded
                ? 'Fine buffer: $bufLen samples · window hint ${_fineWindowSecs}s '
                      '(Path H still owns runtime; no train/bind yet)'
                : 'Loading candidates…',
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'Fine window',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              Expanded(
                child: Slider(
                  value: _fineWindowSecs.toDouble(),
                  min: 30,
                  max: 60,
                  divisions: 6,
                  label: '${_fineWindowSecs}s',
                  onChanged: (v) {
                    setState(() => _fineWindowSecs = v.round());
                    ambient.buffer.window = Duration(seconds: _fineWindowSecs);
                  },
                ),
              ),
            ],
          ),
          TextField(
            controller: _agentCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Agent name',
              labelStyle: TextStyle(color: Colors.white54, fontSize: 11),
              isDense: true,
            ),
          ),
          TextField(
            controller: _labelCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Proposed label',
              labelStyle: TextStyle(color: Colors.white54, fontSize: 11),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: bufLen == 0
                  ? null
                  : () async {
                      await ambient.propose(
                        agentName: _agentCtrl.text.trim().isEmpty
                            ? 'PathH'
                            : _agentCtrl.text.trim(),
                        proposedLabel: _labelCtrl.text.trim().isEmpty
                            ? 'positive'
                            : _labelCtrl.text.trim(),
                      );
                    },
              icon: const Icon(Icons.add_a_photo_outlined, size: 16),
              label: const Text(
                'PROPOSE FROM BUFFER',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'No pending labels. Collect samples (collector running) then propose.',
                style: TextStyle(
                  color: Colors.white30,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...pending.map(
              (c) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.agentName}: ${c.proposedLabel}\n'
                        '${c.compressedSnapshot.length}B snapshot · '
                        '${c.createdAt.toLocal()}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ambient.decide(c.id, confirm: true),
                      child: const Text(
                        'CONFIRM',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ambient.decide(c.id, confirm: false),
                      child: const Text(
                        'REJECT',
                        style: TextStyle(color: Colors.redAccent, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
