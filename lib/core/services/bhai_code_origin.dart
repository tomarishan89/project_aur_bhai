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
        return 'From pool';
      default:
        return 'Yours';
    }
  }
}
