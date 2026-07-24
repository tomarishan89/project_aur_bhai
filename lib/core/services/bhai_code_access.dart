/// Creator-declared access flags on a shared Bhai Code listing.
class BhaiCodeAccess {
  final bool shareModel;
  final bool allowDiligence;
  final bool allowSandboxTest;

  const BhaiCodeAccess({
    this.shareModel = false,
    this.allowDiligence = true,
    this.allowSandboxTest = true,
  });

  static const defaults = BhaiCodeAccess();

  factory BhaiCodeAccess.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return BhaiCodeAccess(
      shareModel: json['shareModel'] as bool? ?? false,
      allowDiligence: json['allowDiligence'] as bool? ?? true,
      allowSandboxTest: json['allowSandboxTest'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'shareModel': shareModel,
    'allowDiligence': allowDiligence,
    'allowSandboxTest': allowSandboxTest,
  };

  BhaiCodeAccess copyWith({
    bool? shareModel,
    bool? allowDiligence,
    bool? allowSandboxTest,
  }) => BhaiCodeAccess(
    shareModel: shareModel ?? this.shareModel,
    allowDiligence: allowDiligence ?? this.allowDiligence,
    allowSandboxTest: allowSandboxTest ?? this.allowSandboxTest,
  );
}
