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
  /// Strip any backtick template that looks like an HTML document so DOM/fetch
  /// APIs inside dashboards do not false-flag the sandbox script.
  String _stripEmbeddedHtmlTemplates(String script) {
    var stripped = script.replaceAllMapped(
      RegExp(
        r"(?:const|let|var)?\s*\w+\s*=\s*`[\s\S]*?`",
        multiLine: true,
      ),
      (match) {
        final block = match.group(0) ?? '';
        final lower = block.toLowerCase();
        if (lower.contains('<!doctype') ||
            lower.contains('<html') ||
            lower.contains('<head') ||
            lower.contains('<body') ||
            lower.contains('<script') ||
            lower.contains('document.') ||
            lower.contains('fetch(')) {
          return 'const __strippedHtml = ``';
        }
        return block;
      },
    );
    // return `...html...` or bare assignment without declaration keyword
    stripped = stripped.replaceAllMapped(
      RegExp(
        r"return\s*`[\s\S]*?(?:<!DOCTYPE|<html|<script|document\.|fetch\()[\s\S]*?`",
        multiLine: true,
        caseSensitive: false,
      ),
      (_) => 'return ``',
    );
    // Also strip anonymous/returned template literals that embed HTML.
    stripped = stripped.replaceAllMapped(
      RegExp(r"`[\s\S]*?<!DOCTYPE[\s\S]*?`", multiLine: true, caseSensitive: false),
      (_) => '``',
    );
    stripped = stripped.replaceAllMapped(
      RegExp(r"`[\s\S]*?<html[\s\S]*?`", multiLine: true, caseSensitive: false),
      (_) => '``',
    );
    stripped = stripped.replaceAllMapped(
      RegExp(r"`[\s\S]*?<script[\s\S]*?`", multiLine: true, caseSensitive: false),
      (_) => '``',
    );
    return stripped;
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
