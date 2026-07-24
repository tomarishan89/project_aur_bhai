import 'package:flutter/material.dart';

import '../../core/services/bhai_code_access.dart';

/// Result of the Friend Circle publish confirm dialog.
class PublishToCircleResult {
  final String license;
  final BhaiCodeAccess access;

  const PublishToCircleResult({required this.license, required this.access});
}

/// License + creator access checkboxes before publishing to Friend Circle.
Future<PublishToCircleResult?> showPublishToCircleDialog(BuildContext context) {
  return showDialog<PublishToCircleResult>(
    context: context,
    builder: (ctx) => const _PublishToCircleDialog(),
  );
}

class _PublishToCircleDialog extends StatefulWidget {
  const _PublishToCircleDialog();

  @override
  State<_PublishToCircleDialog> createState() => _PublishToCircleDialogState();
}

class _PublishToCircleDialogState extends State<_PublishToCircleDialog> {
  bool _shareModel = false;
  bool _allowDiligence = true;
  bool _allowSandboxTest = true;

  BhaiCodeAccess get _access => BhaiCodeAccess(
    shareModel: _shareModel,
    allowDiligence: _allowDiligence,
    allowSandboxTest: _allowSandboxTest,
  );

  void _pickLicense(String license) {
    Navigator.pop(
      context,
      PublishToCircleResult(license: license, access: _access),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Text(
        'Publish to Friend Circle',
        style: TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Friends will see this under FRIEND CIRCLE, then add it to Sandbox.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'CREATOR ACCESS',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: Colors.greenAccent,
              title: const Text(
                'Allow due diligence scan',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              value: _allowDiligence,
              onChanged: (v) => setState(() => _allowDiligence = v ?? true),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: Colors.greenAccent,
              title: const Text(
                'Allow sandbox test',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              value: _allowSandboxTest,
              onChanged: (v) => setState(() => _allowSandboxTest = v ?? true),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: Colors.greenAccent,
              title: const Text(
                'Share model (Path L)',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: const Text(
                'Flag only — model packing not shipped yet',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
              value: _shareModel,
              onChanged: (v) => setState(() => _shareModel = v ?? false),
            ),
            const SizedBox(height: 8),
            const Text(
              'LICENSE',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
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
          onPressed: () => _pickLicense('remix_free'),
          child: const Text(
            'remix_free',
            style: TextStyle(color: Colors.greenAccent),
          ),
        ),
        TextButton(
          onPressed: () => _pickLicense('lineage_indexed'),
          child: const Text(
            'lineage_indexed',
            style: TextStyle(color: Colors.greenAccent),
          ),
        ),
      ],
    );
  }
}
