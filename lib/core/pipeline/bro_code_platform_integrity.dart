/// Platform-level structural checks for ANY Bro Code unit.
///
/// These are intentionally app-agnostic (not Locator/dashboard-specific).
/// They catch wiring failures that block every capability class: HTML vault
/// publish, HTTP side effects, scheduling, IoT commands, etc.
///
/// See also [BroCodeCapabilityJudge] for intent/output verification design.
library;

/// Result of a platform integrity scan.
class BroCodePlatformIntegrityResult {
  final bool ok;
  final List<String> findings;
  final List<String> orphanAssetIds;
  final bool halfThinScript;
  final String? suggestedPublishAssetId;

  const BroCodePlatformIntegrityResult({
    required this.ok,
    this.findings = const [],
    this.orphanAssetIds = const [],
    this.halfThinScript = false,
    this.suggestedPublishAssetId,
  });
}

/// Structural integrity for Bro Code workspaces (script + sidecar assets).
class BroCodePlatformIntegrity {
  BroCodePlatformIntegrity._();

  /// Asset ids referenced via `System.assets['id']` / `System.assets["id"]`.
  static Set<String> referencedAssetIds(String script) {
    final ids = <String>{};
    final re = RegExp(
      r'''System\.assets\s*\[\s*(['"])([^'"]+)\1\s*\]''',
    );
    for (final m in re.allMatches(script)) {
      ids.add(m.group(2)!);
    }
    return ids;
  }

  /// Case-insensitive lookup of [id] in [assets] keys.
  static String? resolveAssetKey(Map<String, String> assets, String id) {
    if (assets.containsKey(id)) return id;
    final lower = id.toLowerCase();
    for (final k in assets.keys) {
      if (k.toLowerCase() == lower) return k;
    }
    return null;
  }

  /// HTML / text assets that look publishable but are never referenced.
  static List<String> orphanAssetIds(
    String script,
    Map<String, String> assets,
  ) {
    final refs = referencedAssetIds(script).map((e) => e.toLowerCase()).toSet();
    // Also treat writeVault(key, System.assets[...]) as referencing the asset.
    final orphans = <String>[];
    for (final entry in assets.entries) {
      final key = entry.key;
      final kl = key.toLowerCase();
      final isHtml = kl.endsWith('.html') ||
          kl.endsWith('.htm') ||
          entry.value.trimLeft().toLowerCase().startsWith('<!doctype') ||
          entry.value.trimLeft().toLowerCase().startsWith('<html');
      final isManifest = kl.contains('manifest') || kl.endsWith('.webmanifest');
      final isSw = kl.endsWith('.sw.js') ||
          kl.contains('service-worker') ||
          kl.contains('serviceworker');
      if (!isHtml && !isManifest && !isSw) continue;
      if (!refs.contains(kl)) {
        orphans.add(key);
      }
    }
    return orphans;
  }

  /// True when script looks like a thin publisher but has trailing junk
  /// after the first top-level `return` inside `execute`.
  ///
  /// Classic failure: agent inserts
  /// `const html = System.assets[…]; writeVault; return '…';`
  /// but leaves the old Leaflet/HTML body after the return → syntax/policy red.
  static bool isHalfThinScript(String script) {
    final refsAsset = referencedAssetIds(script).isNotEmpty;
    final hasWriteVault = script.contains('System.writeVault');
    if (!refsAsset || !hasWriteVault) {
      // Still detect dead code after return even without assets.
      return _hasDeadCodeAfterReturn(script);
    }

    // Thin intent: short script OR has assets ref + writeVault + return.
    if (_hasDeadCodeAfterReturn(script)) return true;

    // Large residual HTML/browser APIs outside a template → half-thin.
    final stripped = _stripTemplatesAndStrings(script);
    final hasBrowserOutside = RegExp(
      r'\b(document\.|window\.|fetch\s*\(|L\.map\s*\(|L\.tileLayer)',
    ).hasMatch(stripped);
    final hasHtmlTagOutside = RegExp(
      r'<(div|script|html|body|head|meta|link)\b',
      caseSensitive: false,
    ).hasMatch(stripped);

    if ((hasBrowserOutside || hasHtmlTagOutside) && refsAsset) {
      return true;
    }
    return false;
  }

  static bool _hasDeadCodeAfterReturn(String script) {
    // Find `return …;` then non-whitespace / non-comment / non-closing-brace content.
    final returnRe = RegExp(r'''\breturn\b[^;]*;''');
    final m = returnRe.firstMatch(script);
    if (m == null) return false;
    final after = script.substring(m.end);
    // Strip closing braces and whitespace/comments of the function.
    var rest = after
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .trim();
    // Only closing braces left is OK.
    rest = rest.replaceAll(RegExp(r'[\s\}]+'), '');
    return rest.isNotEmpty;
  }

  /// Rough strip of `…` / '…' / "…" so browser APIs inside HTML templates
  /// are not mistaken for sandbox DOM abuse here (policy has its own strip).
  static String _stripTemplatesAndStrings(String script) {
    var s = script;
    s = s.replaceAll(RegExp(r'`(?:\\`|[^`])*`'), '""');
    s = s.replaceAll(RegExp(r'"(?:\\.|[^"\\])*"'), '""');
    s = s.replaceAll(RegExp(r"'(?:\\.|[^'\\])*'"), "''");
    return s;
  }

  /// Full structural scan for a Bro Code workspace.
  static BroCodePlatformIntegrityResult check({
    required String script,
    required Map<String, String> assets,
  }) {
    final findings = <String>[];
    final orphans = orphanAssetIds(script, assets);
    final halfThin = isHalfThinScript(script);

    // Orphan HTML assets are always a platform wiring failure when present.
    final htmlOrphans = orphans
        .where((k) {
          final kl = k.toLowerCase();
          return kl.endsWith('.html') ||
              kl.endsWith('.htm') ||
              (assets[k] ?? '')
                  .trimLeft()
                  .toLowerCase()
                  .startsWith('<!doctype');
        })
        .toList();

    if (htmlOrphans.isNotEmpty) {
      findings.add(
        'Orphan asset(s) never referenced by execute(): ${htmlOrphans.join(", ")}. '
        'Wire System.assets["…"] + System.writeVault (or delete unused assets).',
      );
    }

    // Broken asset refs (case / missing).
    for (final id in referencedAssetIds(script)) {
      if (resolveAssetKey(assets, id) == null) {
        findings.add(
          'System.assets["$id"] does not match any workspace asset '
          '(check spelling/case). Known: ${assets.keys.isEmpty ? "(none)" : assets.keys.join(", ")}.',
        );
      }
    }

    if (halfThin) {
      findings.add(
        'Half-thin execute(): script references System.assets / writeVault but '
        'still has dead code after return or browser/HTML residue outside templates. '
        'Replace execute() with a thin publisher that only loads assets and writeVaults.',
      );
    }

    String? suggested;
    if (htmlOrphans.isNotEmpty) {
      suggested = htmlOrphans.first;
    } else {
      for (final k in assets.keys) {
        if (k.toLowerCase().endsWith('.html') || k.toLowerCase().endsWith('.htm')) {
          suggested = k;
          break;
        }
      }
    }

    return BroCodePlatformIntegrityResult(
      ok: findings.isEmpty,
      findings: findings,
      orphanAssetIds: htmlOrphans,
      halfThinScript: halfThin,
      suggestedPublishAssetId: suggested,
    );
  }

  /// Known-good thin execute() that publishes [htmlAssetId] (+ optional PWA sidecars).
  ///
  /// Platform-generic: works for any HTML vault Bro Code, not Locator-specific.
  static String buildThinPublishExecute({
    required String htmlAssetId,
    String? vaultKey,
    Map<String, String> assets = const {},
  }) {
    final key = vaultKey ?? htmlAssetId;
    final resolvedHtml = resolveAssetKey(assets, htmlAssetId) ?? htmlAssetId;
    final buf = StringBuffer();
    buf.writeln('async function execute(params) {');
    buf.writeln('  const html = System.assets["$resolvedHtml"];');
    buf.writeln('  if (!html) {');
    buf.writeln(
      '    throw new Error("Missing System.assets[\\"$resolvedHtml\\"]");',
    );
    buf.writeln('  }');
    buf.writeln('  await System.writeVault("$key", html, "text/html");');

    String? manifestId;
    String? swId;
    for (final k in assets.keys) {
      final kl = k.toLowerCase();
      if (manifestId == null &&
          (kl.endsWith('.webmanifest') || kl.contains('manifest'))) {
        manifestId = k;
      }
      if (swId == null &&
          (kl.endsWith('.sw.js') ||
              kl.contains('service-worker') ||
              kl.contains('serviceworker'))) {
        swId = k;
      }
    }
    if (manifestId != null) {
      buf.writeln('  const manifest = System.assets["$manifestId"];');
      buf.writeln('  if (manifest) {');
      buf.writeln(
        '    await System.writeVault("$manifestId", manifest, "application/manifest+json");',
      );
      buf.writeln('  }');
    }
    if (swId != null) {
      buf.writeln('  const sw = System.assets["$swId"];');
      buf.writeln('  if (sw) {');
      buf.writeln(
        '    await System.writeVault("$swId", sw, "application/javascript");',
      );
      buf.writeln('  }');
    }

    buf.writeln(
      '  return "Ready. Open it from the Vault Dashboards panel on the Agents page.";',
    );
    buf.writeln('}');
    buf.writeln();
    return buf.toString();
  }

  /// Whether integrity failures are auto-repairable by host thin rewrite.
  static bool canAutoRepair(BroCodePlatformIntegrityResult result) {
    if (result.ok) return false;
    if (result.suggestedPublishAssetId == null) return false;
    return result.orphanAssetIds.isNotEmpty || result.halfThinScript;
  }
}
