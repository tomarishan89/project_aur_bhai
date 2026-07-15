import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agents/js_agent_adapter.dart';
import 'js_agent_registry.dart';

/// Result of automated due-diligence on agent JS (MS-USER-ECOSYSTEM-ENG3).
class DueDiligenceResult {
  final bool passed;
  final List<String> findings;

  const DueDiligenceResult({required this.passed, this.findings = const []});

  bool get flagged => !passed;
}

/// UI-visible promotion request after authoring/refinement (MS-USER-ECOSYSTEM-ENG4).
class PendingPromotion {
  final String agentName;
  final DueDiligenceResult scan;
  final bool isRefinement;

  const PendingPromotion({
    required this.agentName,
    required this.scan,
    this.isRefinement = false,
  });
}

/// Scans agent scripts and gates promotion with vault password (MS-USER-ECOSYSTEM-ENG3/ENG4).
class AgentVerificationService extends ChangeNotifier {
  static const _vaultPasswordKey = 'vault_password_hash';

  PendingPromotion? _pendingPromotion;
  String? _passwordHash;
  int _promotionRequestId = 0;

  AgentVerificationService() {
    _loadPassword();
  }

  PendingPromotion? get pendingPromotion => _pendingPromotion;
  int get promotionRequestId => _promotionRequestId;
  bool get hasVaultPassword => _passwordHash != null && _passwordHash!.isNotEmpty;

  void clearPendingPromotion() {
    _pendingPromotion = null;
    notifyListeners();
  }

  void requestPromotion({
    required String agentName,
    required DueDiligenceResult scan,
    bool isRefinement = false,
  }) {
    _promotionRequestId++;
    _pendingPromotion = PendingPromotion(
      agentName: agentName,
      scan: scan,
      isRefinement: isRefinement,
    );
    notifyListeners();
  }

  /// Heuristic static analysis — no network, runs 100% on-device.
  DueDiligenceResult scanScript(String script) {
    final findings = <String>[];
    final sandboxOnly = _stripEmbeddedHtmlTemplates(script);
    final lower = sandboxOnly.toLowerCase();

    if (RegExp(r'\b(delete|drop|truncate|alter)\s+(from|table|into)\b',
            caseSensitive: false)
        .hasMatch(sandboxOnly)) {
      findings.add('Destructive SQL pattern detected (DELETE/DROP/TRUNCATE/ALTER).');
    }

    if (RegExp(
      r"system\.sendhttp\s*\(\s*['\x22]https?://(?!localhost|127\.0\.0\.1)",
      caseSensitive: false,
    ).hasMatch(lower)) {
      findings.add('Outbound HTTP to an external host via System.sendHTTP.');
    }

    if (RegExp(r'\beval\s*\(', caseSensitive: false).hasMatch(sandboxOnly) ||
        RegExp(r'new\s+Function\s*\(', caseSensitive: false).hasMatch(sandboxOnly)) {
      findings.add('Dynamic code execution pattern (eval / Function constructor).');
    }

    if (lower.contains('document.') ||
        lower.contains('window.') ||
        lower.contains('fetch(') ||
        lower.contains('xmlhttprequest')) {
      findings.add('Browser/DOM API usage outside the System bridge sandbox.');
    }

    if (RegExp(
      r"(api[_-]?key|secret|password|token)\s*[:=]",
      caseSensitive: false,
    ).hasMatch(sandboxOnly)) {
      findings.add('Hard-coded credential-like key in script source.');
    }

    if (RegExp(r'system\.querysql\s*\([^)]*\b(insert|update|delete|drop)\b',
            caseSensitive: false)
        .hasMatch(lower)) {
      findings.add('Non-SELECT SQL attempted via System.querySQL.');
    }

    return DueDiligenceResult(
      passed: findings.isEmpty,
      findings: findings,
    );
  }

  /// Dashboard HTML embedded in agent scripts runs in the browser, not QuickJS.
  /// Strip complete backtick templates that look like HTML. The scanner must
  /// respect escaped backticks (`\``) used by JavaScript embedded inside the
  /// HTML; a non-greedy regex stops at the first escaped inner template and
  /// leaks browser APIs into the sandbox scan.
  String _stripEmbeddedHtmlTemplates(String script) {
    // Prefer explicit HTML document boundaries. This also handles a malformed
    // dashboard whose inner JavaScript backticks were not escaped: syntax
    // validation will still reject it, but due diligence should not mislabel
    // browser code between <!DOCTYPE ... </html> as QuickJS-scope DOM access.
    final htmlDocuments = script.replaceAllMapped(
      RegExp(
        r'`\s*<!doctype[\s\S]*?</html>\s*`',
        caseSensitive: false,
        multiLine: true,
      ),
      (_) => '``',
    );

    final out = StringBuffer();
    var cursor = 0;
    while (cursor < htmlDocuments.length) {
      final start = htmlDocuments.indexOf('`', cursor);
      if (start < 0) {
        out.write(htmlDocuments.substring(cursor));
        break;
      }

      var end = start + 1;
      while (end < htmlDocuments.length) {
        if (htmlDocuments.codeUnitAt(end) == 0x60 &&
            !_isEscaped(htmlDocuments, end)) {
          break;
        }
        end++;
      }
      if (end >= htmlDocuments.length) {
        out.write(htmlDocuments.substring(cursor));
        break;
      }

      out.write(htmlDocuments.substring(cursor, start));
      final template = htmlDocuments.substring(start, end + 1);
      final lower = template.toLowerCase();
      final isHtml = lower.contains('<!doctype') ||
          lower.contains('<html') ||
          lower.contains('<head') ||
          lower.contains('<body') ||
          lower.contains('<script');
      out.write(isHtml ? '``' : template);
      cursor = end + 1;
    }
    return out.toString();
  }

  bool _isEscaped(String source, int index) {
    var slashes = 0;
    for (var i = index - 1; i >= 0 && source.codeUnitAt(i) == 0x5c; i--) {
      slashes++;
    }
    return slashes.isOdd;
  }

  Future<void> _loadPassword() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _passwordHash = prefs.getString(_vaultPasswordKey);
    } catch (e) {
      debugPrint('[AgentVerification] Password load error: $e');
    }
  }

  String _hashPassword(String password) {
    // Simple local gate — not cryptographic identity; sufficient for vault promotion.
    return password.codeUnits.fold<int>(0, (a, b) => a * 31 + b).toString();
  }

  Future<bool> setVaultPassword(String password) async {
    if (password.trim().length < 4) return false;
    final hash = _hashPassword(password.trim());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_vaultPasswordKey, hash);
      _passwordHash = hash;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[AgentVerification] Password save error: $e');
      return false;
    }
  }

  Future<bool> verifyVaultPassword(String password) async {
    if (_passwordHash == null) return false;
    return _hashPassword(password.trim()) == _passwordHash;
  }

  /// Promote agent to C2 after clean scan or device authentication override.
  Future<bool> promoteToVerified({
    required JsAgentRegistry registry,
    required String agentName,
    bool deviceAuthenticated = false,
    DueDiligenceResult? priorScan,
  }) async {
    final bundle = await registry.exportAgentBundle(agentName);
    final scan = priorScan ?? scanScript(bundle?['script'] as String? ?? '');

    if (scan.flagged && !deviceAuthenticated) return false;

    final ok = await registry.updateSecurityClass(
      agentName,
      AgentSecurityClass.c2Verified,
    );
    if (ok) {
      clearPendingPromotion();
    }
    return ok;
  }
}

final agentVerificationProvider = ChangeNotifierProvider<AgentVerificationService>((ref) {
  return AgentVerificationService();
});
