/// Validates edge-server dashboard URLs so Open never silently hits `/` or `/api/*`.

/// True when [url] is `http(s)://host:port/vault/<non-empty-key>`.
bool isVaultDashboardUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;

  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.length < 2) return false;
  if (segments.first != 'vault') return false;

  final key = segments.sublist(1).join('/');
  return key.isNotEmpty;
}

/// Human-readable reason when [url] is not a vault dashboard URL; null if OK.
String? vaultDashboardUrlError(String url) {
  if (isVaultDashboardUrl(url)) return null;
  final uri = Uri.tryParse(url.trim());
  final path = uri?.path.isEmpty ?? true ? '/' : uri!.path;
  return 'Not a dashboard URL (got "$path"). Expected …/vault/<name.html> — '
      'server root and /api/* are not dashboards.';
}

/// Normalize a vault key for URL building; throws if empty/unsafe.
String normalizeVaultKeyForUrl(String key) {
  final k = key.trim();
  if (k.isEmpty) {
    throw ArgumentError.value(key, 'key', 'vault key must be non-empty');
  }
  if (k.contains('..') || k.startsWith('/')) {
    throw ArgumentError.value(key, 'key', 'vault key must be a plain asset id');
  }
  return k;
}
