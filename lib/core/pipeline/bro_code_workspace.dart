/// In-memory working copy of one Bro Code unit (vault unchanged until APPLY).
class BroCodeWorkspace {
  String name;
  String description;
  Map<String, dynamic> inputSchema;
  String script;
  final Map<String, String> assets;

  BroCodeWorkspace({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.script,
    Map<String, String>? assets,
  }) : assets = Map<String, String>.from(assets ?? const {});

  BroCodeWorkspace copy() => BroCodeWorkspace(
        name: name,
        description: description,
        inputSchema: Map<String, dynamic>.from(inputSchema),
        script: script,
        assets: Map<String, String>.from(assets),
      );

  int get scriptCharCount => script.length;

  String excerptAroundLine(int line1Based, {int radius = 12}) {
    final lines = script.split('\n');
    if (lines.isEmpty) return script;
    final idx = (line1Based - 1).clamp(0, lines.length - 1);
    final start = (idx - radius).clamp(0, lines.length - 1);
    final end = (idx + radius).clamp(0, lines.length - 1);
    final out = StringBuffer();
    out.writeln('lines ${start + 1}-${end + 1} of ${lines.length}:');
    for (var i = start; i <= end; i++) {
      final marker = i == idx ? '>>' : '  ';
      out.writeln('$marker${(i + 1).toString().padLeft(4)}| ${lines[i]}');
    }
    return out.toString();
  }
}
