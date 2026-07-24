import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/agents/agent_base.dart';
import '../../core/agents/js_agent_adapter.dart';
import '../../core/services/agent_service.dart';
import '../../core/services/bhai_code_origin.dart';
import '../../core/services/sandbox_queue_service.dart';
import 'bhai_code_preview_sheet.dart';

IconData _originIcon(String? source) {
  switch (BhaiCodeOrigin.normalize(source)) {
    case BhaiCodeOrigin.friendCircle:
      return Icons.groups_outlined;
    case BhaiCodeOrigin.pool:
      return Icons.public;
    default:
      return Icons.person_outline;
  }
}

/// BHAI LOG Sandbox — unverified installs (C4/C3) + test-later queue.
class SandboxQueueTab extends ConsumerWidget {
  final void Function(BuildContext context, WidgetRef ref, AurBhaiAgent agent)
  onOpenInstalled;

  const SandboxQueueTab({super.key, required this.onOpenInstalled});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentServiceProvider).agents;
    final installed = agents.where((a) {
      if (a is! JsAgentAdapter) return false;
      return a.securityClass == AgentSecurityClass.c4Unverified ||
          a.securityClass == AgentSecurityClass.c3DueDiligence;
    }).toList();
    final queue = ref.watch(sandboxQueueProvider);

    if (!queue.isLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.lightBlueAccent),
      );
    }

    if (installed.isEmpty && queue.items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sandbox is empty.\nAdd a Bhai from Sabke or Friend Circle, or use Test later.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        if (installed.isNotEmpty) ...[
          const Text(
            'ON THIS DEVICE — NOT MERE YET',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.0,
            ),
            itemCount: installed.length,
            itemBuilder: (context, index) {
              final a = installed[index];
              final js = a as JsAgentAdapter;
              final origin = BhaiCodeOrigin.label(js.source);
              return GestureDetector(
                onTap: () => onOpenInstalled(context, ref, a),
                onLongPress: () => openInstalledBhaiPreview(context, ref, a),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF161616),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _originIcon(js.source),
                            color: Colors.amberAccent,
                            size: 26,
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
                          const SizedBox(height: 2),
                          Text(
                            origin,
                            style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 7,
                            ),
                          ),
                        ],
                      ),
                      if (js.diligencePassed)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            Icons.check_circle,
                            color: Colors.greenAccent,
                            size: 14,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
        if (queue.items.isNotEmpty) ...[
          const Text(
            'TEST LATER',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          ...queue.items.map((item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF161616),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.lightBlueAccent.withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.science,
                          color: Colors.lightBlueAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white38,
                            size: 18,
                          ),
                          onPressed: () =>
                              ref.read(sandboxQueueProvider).remove(item.id),
                        ),
                      ],
                    ),
                    Text(
                      item.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Queued ${DateFormat('MMM d, HH:mm').format(item.enqueuedAt.toLocal())}',
                      style: const TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                      ),
                    ),
                    if (item.lastResult != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.lastResult!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 10,
                          fontFamily: 'Courier',
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => BhaiCodePreviewSheet.open(
                          context,
                          listing: item.toListing(),
                          showPickup: true,
                        ),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('OPEN'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}
