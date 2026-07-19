import 'dart:convert';

/// ML metadata persisted on Bro Code schema (MS-MODEL-META — S8 first rung).
class BroCodeMlMeta {
  final bool usesModel;
  final String maturity; // heuristic_only | collecting | ready_to_train | bound
  final Map<String, dynamic> labelSchema;
  final Map<String, dynamic> capturePolicy;
  final Duration? fineWindow;

  const BroCodeMlMeta({
    this.usesModel = false,
    this.maturity = 'heuristic_only',
    this.labelSchema = const {},
    this.capturePolicy = const {},
    this.fineWindow,
  });

  Map<String, dynamic> toJson() => {
        'usesModel': usesModel,
        'maturity': maturity,
        'labelSchema': labelSchema,
        'capturePolicy': capturePolicy,
        if (fineWindow != null) 'fineWindowSeconds': fineWindow!.inSeconds,
      };

  factory BroCodeMlMeta.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const BroCodeMlMeta();
    final secs = json['fineWindowSeconds'] as int?;
    return BroCodeMlMeta(
      usesModel: json['usesModel'] as bool? ?? false,
      maturity: json['maturity'] as String? ?? 'heuristic_only',
      labelSchema: Map<String, dynamic>.from(
        (json['labelSchema'] as Map?) ?? const {},
      ),
      capturePolicy: Map<String, dynamic>.from(
        (json['capturePolicy'] as Map?) ?? const {},
      ),
      fineWindow: secs == null ? null : Duration(seconds: secs),
    );
  }

  static BroCodeMlMeta? fromSchemaJson(String? schemaJson) {
    if (schemaJson == null || schemaJson.isEmpty) return null;
    try {
      final map = jsonDecode(schemaJson) as Map<String, dynamic>;
      final ml = map['ml'];
      if (ml is Map) {
        return BroCodeMlMeta.fromJson(Map<String, dynamic>.from(ml));
      }
    } catch (_) {}
    return null;
  }

  /// Merge into an existing schema map under `ml`.
  static Map<String, dynamic> mergeIntoSchema(
    Map<String, dynamic> schema,
    BroCodeMlMeta meta,
  ) {
    final next = Map<String, dynamic>.from(schema);
    next['ml'] = meta.toJson();
    return next;
  }
}
