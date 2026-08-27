/// Immutable record of an authoring or remix contribution in a Bhai Code's history.
class LineageEntry {
  final String author;
  final String version;
  final DateTime timestamp;
  final String note;

  const LineageEntry({
    required this.author,
    required this.version,
    required this.timestamp,
    required this.note,
  });

  /// Formatted handle ensuring '@' prefix.
  String get displayHandle {
    final trimmed = author.trim();
    if (trimmed.isEmpty) return '@unknown';
    return trimmed.startsWith('@') ? trimmed : '@$trimmed';
  }

  factory LineageEntry.fromJson(Map<String, dynamic> json) {
    DateTime parsedTime;
    try {
      parsedTime = DateTime.parse(json['timestamp'] as String? ?? '');
    } catch (_) {
      parsedTime = DateTime.now();
    }

    return LineageEntry(
      author: json['author'] as String? ?? '@unknown',
      version: json['version'] as String? ?? '1.0.0',
      timestamp: parsedTime,
      note: json['note'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'author': author,
    'version': version,
    'timestamp': timestamp.toIso8601String(),
    'note': note,
  };

  @override
  String toString() => '$displayHandle ($version): $note';
}
