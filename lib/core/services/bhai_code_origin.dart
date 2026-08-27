/// Where a Bhai Code on this device came from (vault schema `source`).
class BhaiCodeOrigin {
  static const self = 'self';
  static const pool = 'pool';
  static const friendCircle = 'friend_circle';

  /// Legacy pickup tag from earlier marketplace shell.
  static const legacyMarketplaceLocal = 'marketplace_local';

  static String normalize(String? raw) {
    switch (raw) {
      case friendCircle:
        return friendCircle;
      case pool:
      case legacyMarketplaceLocal:
        return pool;
      case self:
        return self;
      default:
        // Unknown / missing: treat as self-authored for display.
        return self;
    }
  }

  static String label(String? raw) {
    switch (normalize(raw)) {
      case friendCircle:
        return 'Friend Circle';
      case pool:
        return '@core';
      default:
        return '@you';
    }
  }

  /// Formats any string into a normalized `@handle`.
  static String formatHandle(String? raw, {String fallback = '@you'}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    final trimmed = raw.trim();
    return trimmed.startsWith('@') ? trimmed : '@$trimmed';
  }

  /// Resolves the glanceable author handle for UI badges and cards.
  static String handleFor({
    required String source,
    String? author,
    String userHandle = '@you',
  }) {
    final normalized = normalize(source);
    if (normalized == pool) return '@core';
    if (author != null && author.trim().isNotEmpty && author.trim() != 'Aur Bhai Team') {
      return formatHandle(author);
    }
    if (normalized == self) return formatHandle(userHandle);
    return '@friend';
  }

  static bool isCore(String? sourceOrHandle) {
    if (sourceOrHandle == null) return false;
    final normalized = normalize(sourceOrHandle);
    if (normalized == pool) return true;
    final formatted = formatHandle(sourceOrHandle);
    return formatted.toLowerCase() == '@core';
  }

  static bool isSelf(String? sourceOrHandle, {String myHandle = '@you'}) {
    if (sourceOrHandle == null) return false;
    final normalized = normalize(sourceOrHandle);
    if (normalized == self && sourceOrHandle == self) return true;
    final formatted = formatHandle(sourceOrHandle);
    final myFormatted = formatHandle(myHandle);
    return formatted.toLowerCase() == myFormatted.toLowerCase() || formatted.toLowerCase() == '@you';
  }
}

