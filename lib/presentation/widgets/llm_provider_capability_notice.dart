import 'package:flutter/material.dart';

import '../../core/services/llm/llm_provider_factory.dart';

/// Amber callout when the selected BYOK provider cannot handle voice audio.
class LlmProviderCapabilityNotice extends StatelessWidget {
  const LlmProviderCapabilityNotice({
    super.key,
    required this.providerId,
    this.dense = false,
  });

  final String providerId;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final notice = LlmProviderFactory.capabilityNotice(providerId);
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: dense ? 8 : 12, bottom: dense ? 4 : 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.45)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 10 : 12,
            vertical: dense ? 8 : 10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: dense ? 16 : 18,
                color: Colors.amberAccent,
              ),
              SizedBox(width: dense ? 8 : 10),
              Expanded(
                child: Text(
                  notice,
                  style: TextStyle(
                    color: Colors.amber.shade100,
                    fontSize: dense ? 11 : 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
