import 'package:flutter/material.dart';

import '../../core/services/agent_verification_service.dart';

/// Separates policy-scan findings from syntax/runtime (MS-DUE-DILIGENCE-UX1–3).
class DueDiligenceFindingsList extends StatelessWidget {
  final DueDiligenceResult scan;
  final String? syntaxNote;

  const DueDiligenceFindingsList({
    super.key,
    required this.scan,
    this.syntaxNote,
  });

  @override
  Widget build(BuildContext context) {
    final policy = scan.findings.where((f) => f.category == 'policy').toList();
    final blocking = policy.where(
      (f) => f.severity == 'blocking' && !f.likelyFalsePositive,
    );
    final warnings = policy.where(
      (f) => f.severity != 'blocking' || f.likelyFalsePositive,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Policy scan (does not execute your agent)',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        if (syntaxNote != null && syntaxNote!.isNotEmpty) ...[
          Text(
            'Syntax / last RUN: $syntaxNote',
            style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
          ),
          const SizedBox(height: 6),
        ],
        if (scan.passed)
          const Text(
            'No policy findings.',
            style: TextStyle(color: Colors.greenAccent, fontSize: 11),
          )
        else ...[
          if (blocking.isNotEmpty) ...[
            const Text(
              'Blocking',
              style: TextStyle(color: Colors.redAccent, fontSize: 10),
            ),
            ...blocking.map(_tile),
          ],
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Warnings / likely false positives',
              style: TextStyle(color: Colors.amber, fontSize: 10),
            ),
            ...warnings.map(_tile),
          ],
        ],
      ],
    );
  }

  Widget _tile(DueDiligenceFinding f) {
    final color = f.likelyFalsePositive
        ? Colors.white38
        : (f.severity == 'blocking' ? Colors.redAccent : Colors.amber);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• [${f.severity}] ${f.code}: ${f.message}'
            '${f.likelyFalsePositive ? " (likely HTML/DOM false positive)" : ""}',
            style: TextStyle(color: color, fontSize: 11),
          ),
          if (f.improveHint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(
                'IMPROVE: ${f.improveHint}',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}
