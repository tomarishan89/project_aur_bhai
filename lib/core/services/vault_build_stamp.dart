import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';

/// Host-owned vault HTML build stamps (not authored by Bro Code).
String vaultContentHash(String body) {
  final digest = sha256.convert(utf8.encode(body));
  return digest.toString().substring(0, 8);
}

String formatVaultBuildId({
  required String hash,
  required DateTime updatedAt,
}) {
  final local = updatedAt.toLocal();
  final stamp = DateFormat('yyyy-MM-dd HH:mm').format(local);
  return '$hash · $stamp';
}

/// Resolve build id from stored metadata, computing hash on read for legacy rows.
String resolveVaultBuildId({
  required String value,
  String? contentHash,
  String? updatedAtIso,
}) {
  final hash = (contentHash != null && contentHash.isNotEmpty)
      ? contentHash
      : vaultContentHash(value);
  DateTime updatedAt;
  if (updatedAtIso != null && updatedAtIso.isNotEmpty) {
    updatedAt = DateTime.tryParse(updatedAtIso)?.toLocal() ?? DateTime.now();
  } else {
    updatedAt = DateTime.now();
  }
  return formatVaultBuildId(hash: hash, updatedAt: updatedAt);
}

final _metaRe = RegExp(
  r'''<meta\s+name=["']aur-bhai-build["'][^>]*>\s*''',
  caseSensitive: false,
);
final _badgeRe = RegExp(
  r'''<div\s+id=["']aur-bhai-build["'][^>]*>.*?</div>\s*''',
  caseSensitive: false,
  dotAll: true,
);

/// Inject (or replace) host build meta + corner badge. Idempotent.
String injectHtmlBuildStamp(String html, String buildId) {
  var out = html.replaceAll(_metaRe, '').replaceAll(_badgeRe, '');
  final escaped = const HtmlEscape().convert(buildId);
  final meta =
      '<meta name="aur-bhai-build" content="$escaped">';
  final badge = '''
<div id="aur-bhai-build" style="position:fixed;right:8px;bottom:8px;z-index:2147483647;padding:4px 8px;border-radius:4px;background:rgba(0,0,0,0.72);color:#b8f5c0;font:11px/1.3 ui-monospace,Menlo,Consolas,monospace;pointer-events:none;">build $escaped</div>''';

  final headClose = RegExp(r'</head>', caseSensitive: false);
  if (headClose.hasMatch(out)) {
    out = out.replaceFirst(headClose, '$meta\n</head>');
  } else {
    out = '$meta\n$out';
  }

  final bodyClose = RegExp(r'</body>', caseSensitive: false);
  if (bodyClose.hasMatch(out)) {
    out = out.replaceFirst(bodyClose, '$badge\n</body>');
  } else {
    out = '$out\n$badge';
  }
  return out;
}
