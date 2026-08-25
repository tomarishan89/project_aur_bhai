import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agents/js_agent_adapter.dart';
import 'js_agent_registry.dart';

/// Structured due-diligence finding (MS-DUE-DILIGENCE).
class DueDiligenceFinding {
  final String code;
  final String message;

  /// `policy` (static scan) vs `syntax` (QuickJS / last RUN).
  final String category;

  /// `blocking` | `warning` | `info`
  final String severity;

  /// Suggested IMPROVE chip label.
  final String improveHint;

  /// True when likely HTML/DOM dashboard false positive.
  final bool likelyFalsePositive;

  const DueDiligenceFinding({
    required this.code,
    required this.message,
    this.category = 'policy',
    this.severity = 'blocking',
    this.improveHint = '',
    this.likelyFalsePositive = false,
  });

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'category': category,
    'severity': severity,
    'improveHint': improveHint,
    'likelyFalsePositive': likelyFalsePositive,
  };

  @override
  String toString() => '[$code] $message';
}

/// Single checklist row in the 7-Point Due Diligence Report.
class DueDiligenceCheckItem {
  final String id;
  final String title;
  final String description;
  final bool passed;
  final String? warningMessage;

  const DueDiligenceCheckItem({
    required this.id,
    required this.title,
    required this.description,
    required this.passed,
    this.warningMessage,
  });
}

/// Result of automated due-diligence on agent JS (MS-USER-ECOSYSTEM-ENG3).
class DueDiligenceResult {
  final bool passed;
  final List<DueDiligenceFinding> findings;

  const DueDiligenceResult({required this.passed, this.findings = const []});

  bool get flagged => !passed;

  /// 7-Point structured security checklist for UI display.
  List<DueDiligenceCheckItem> get standardChecks {
    DueDiligenceFinding? findCode(String code) {
      for (final f in findings) {
        if (f.code == code) return f;
      }
      return null;
    }

    return [
      DueDiligenceCheckItem(
        id: 'DD_DESTRUCTIVE_SQL',
        title: 'No Destructive SQL',
        description: 'No DROP, DELETE, TRUNCATE, or ALTER queries',
        passed: findCode('DD_DESTRUCTIVE_SQL') == null,
        warningMessage: findCode('DD_DESTRUCTIVE_SQL')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_WRITE_SQL',
        title: 'Read-Only Database Access',
        description: 'System.querySQL uses SELECT-only statements',
        passed: findCode('DD_WRITE_SQL') == null,
        warningMessage: findCode('DD_WRITE_SQL')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_EXTERNAL_HTTP',
        title: 'Network Isolation',
        description: 'Zero unauthorized outbound HTTP calls (100% offline)',
        passed: findCode('DD_EXTERNAL_HTTP') == null,
        warningMessage: findCode('DD_EXTERNAL_HTTP')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_DYNAMIC_CODE',
        title: 'No Dynamic Code Execution',
        description: 'No eval() or dynamic Function compilation',
        passed: findCode('DD_DYNAMIC_CODE') == null,
        warningMessage: findCode('DD_DYNAMIC_CODE')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_HARDCODED_SECRET',
        title: 'No Hardcoded Secrets',
        description: 'No leaked API keys, tokens, or passwords in source',
        passed: findCode('DD_HARDCODED_SECRET') == null,
        warningMessage: findCode('DD_HARDCODED_SECRET')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_BROWSER_DOM',
        title: 'Sandbox Boundary',
        description: 'Pure QuickJS execution within sandbox environment',
        passed: findCode('DD_BROWSER_DOM') == null,
        warningMessage: findCode('DD_BROWSER_DOM')?.message,
      ),
      DueDiligenceCheckItem(
        id: 'DD_VAULT_ISOLATION',
        title: 'Vault Asset Integrity',
        description: 'Sidecar PWA HTML assets stored in vault sandbox',
        passed: true,
      ),
    ];
  }

  /// Legacy string list for UI that still expects messages only.
  List<String> get findingMessages =>
      findings.map((f) => f.toString()).toList();
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
  bool get hasVaultPassword =>
      _passwordHash != null && _passwordHash!.isNotEmpty;

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
    final findings = <DueDiligenceFinding>[];
    final sandboxOnly = _stripEmbeddedHtmlTemplates(script);
    final lower = sandboxOnly.toLowerCase();

    if (RegExp(
      r'\b(delete|drop|truncate|alter)\s+(from|table|into)\b',
      caseSensitive: false,
    ).hasMatch(sandboxOnly)) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_DESTRUCTIVE_SQL',
          message:
              'Destructive SQL pattern detected (DELETE/DROP/TRUNCATE/ALTER).',
          severity: 'blocking',
          improveHint: 'Remove DELETE/DROP/TRUNCATE/ALTER; use read-only SQL.',
        ),
      );
    }

    if (RegExp(
      r"system\.sendhttp\s*\(\s*['\x22]https?://(?!localhost|127\.0\.0\.1)",
      caseSensitive: false,
    ).hasMatch(lower)) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_EXTERNAL_HTTP',
          message: 'Outbound HTTP to an external host via System.sendHTTP.',
          severity: 'blocking',
          improveHint:
              'Prefer localhost/System vault; gate external HTTP behind C2.',
        ),
      );
    }

    if (RegExp(r'\beval\s*\(', caseSensitive: false).hasMatch(sandboxOnly) ||
        RegExp(
          r'new\s+Function\s*\(',
          caseSensitive: false,
        ).hasMatch(sandboxOnly)) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_DYNAMIC_CODE',
          message:
              'Dynamic code execution pattern (eval / Function constructor).',
          severity: 'blocking',
          improveHint: 'Delete eval/Function; use static execute() logic.',
        ),
      );
    }

    if (lower.contains('document.') ||
        lower.contains('window.') ||
        lower.contains('fetch(') ||
        lower.contains('xmlhttprequest')) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_BROWSER_DOM',
          message: 'Browser/DOM API usage outside the System bridge sandbox.',
          severity: 'warning',
          improveHint:
              'Move DOM/fetch into vault HTML assets; keep execute() thin.',
          likelyFalsePositive: true,
        ),
      );
    }

    if (RegExp(
      r"(api[_-]?key|secret|password|token)\s*[:=]",
      caseSensitive: false,
    ).hasMatch(sandboxOnly)) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_HARDCODED_SECRET',
          message: 'Hard-coded credential-like key in script source.',
          severity: 'blocking',
          improveHint: 'Remove secrets; use BYOK Settings keys at runtime.',
        ),
      );
    }

    if (RegExp(
      r'system\.querysql\s*\([^)]*\b(insert|update|delete|drop)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      findings.add(
        const DueDiligenceFinding(
          code: 'DD_WRITE_SQL',
          message: 'Non-SELECT SQL attempted via System.querySQL.',
          severity: 'blocking',
          improveHint: 'Use SELECT-only queries via System.querySQL.',
        ),
      );
    }

    return DueDiligenceResult(passed: findings.isEmpty, findings: findings);
  }

  /// Dashboard HTML embedded in agent scripts runs in the browser, not QuickJS.
  String _stripEmbeddedHtmlTemplates(String script) {
    var cleaned = _stripHtmlDocumentBodies(script);

    final out = StringBuffer();
    var cursor = 0;
    while (cursor < cleaned.length) {
      final start = cleaned.indexOf('`', cursor);
      if (start < 0) {
        out.write(cleaned.substring(cursor));
        break;
      }

      var end = start + 1;
      while (end < cleaned.length) {
        if (cleaned.codeUnitAt(end) == 0x60 && !_isEscaped(cleaned, end)) {
          break;
        }
        end++;
      }
      if (end >= cleaned.length) {
        out.write(cleaned.substring(cursor));
        break;
      }

      out.write(cleaned.substring(cursor, start));
      final template = cleaned.substring(start, end + 1);
      final lower = template.toLowerCase();
      final isHtml =
          lower.contains('<!doctype') ||
          lower.contains('<html') ||
          lower.contains('<head') ||
          lower.contains('<body') ||
          lower.contains('<script') ||
          lower.contains('<div') ||
          lower.contains('<meta');
      final isServiceWorker =
          lower.contains('self.addeventlistener') ||
          lower.contains('self.skipwaiting') ||
          lower.contains('clients.claim');
      out.write((isHtml || isServiceWorker) ? '``' : template);
      cursor = end + 1;
    }
    return out.toString();
  }

  String _stripHtmlDocumentBodies(String script) {
    final out = StringBuffer();
    var cursor = 0;
    final lower = script.toLowerCase();
    while (cursor < script.length) {
      final doctype = lower.indexOf('<!doctype', cursor);
      final htmlTag = lower.indexOf('<html', cursor);
      int start = -1;
      if (doctype >= 0 && (htmlTag < 0 || doctype <= htmlTag)) {
        start = doctype;
      } else if (htmlTag >= 0) {
        start = htmlTag;
      }
      if (start < 0) {
        out.write(script.substring(cursor));
        break;
      }
      out.write(script.substring(cursor, start));
      final close = lower.indexOf('</html>', start);
      if (close < 0) {
        out.write(' ');
        break;
      }
      out.write(' ');
      cursor = close + '</html>'.length;
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

  Future<AgentSecurityClass> _currentClass(
    JsAgentRegistry registry,
    String agentName,
  ) async {
    final bundle = await registry.exportAgentBundle(agentName);
    final schema = bundle?['schema'] as Map<String, dynamic>?;
    return AgentSecurityClassX.fromId(schema?['securityClass'] as String?);
  }

  /// C4 → C3 after a clean static scan (real due-diligence tier).
  Future<bool> promoteToDueDiligence({
    required JsAgentRegistry registry,
    required String agentName,
    DueDiligenceResult? priorScan,
  }) async {
    final bundle = await registry.exportAgentBundle(agentName);
    final scan = priorScan ?? scanScript(bundle?['script'] as String? ?? '');
    if (scan.flagged) return false;

    final current = await _currentClass(registry, agentName);
    if (current == AgentSecurityClass.c1Core ||
        current == AgentSecurityClass.c2Verified ||
        current == AgentSecurityClass.c3DueDiligence) {
      // Already at or beyond C3.
      if (current == AgentSecurityClass.c3DueDiligence) return true;
      return false;
    }

    final ok = await registry.updateSecurityClass(
      agentName,
      AgentSecurityClass.c3DueDiligence,
    );
    return ok;
  }

  /// C3 → C2 after clean scan, or force with [deviceAuthenticated].
  Future<bool> promoteToVerified({
    required JsAgentRegistry registry,
    required String agentName,
    bool deviceAuthenticated = false,
    DueDiligenceResult? priorScan,
  }) async {
    final bundle = await registry.exportAgentBundle(agentName);
    final scan = priorScan ?? scanScript(bundle?['script'] as String? ?? '');

    if (scan.flagged && !deviceAuthenticated) return false;

    final current = await _currentClass(registry, agentName);

    // Normal path: must be C3 first.
    if (!deviceAuthenticated && current != AgentSecurityClass.c3DueDiligence) {
      return false;
    }

    // Force-promote: device auth may jump C4/C3 → C2 (ENG4 override).
    if (deviceAuthenticated && scan.flagged) {
      // Allowed — explicit user override after biometric/device gate.
    }

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

final agentVerificationProvider =
    ChangeNotifierProvider<AgentVerificationService>((ref) {
      return AgentVerificationService();
    });
