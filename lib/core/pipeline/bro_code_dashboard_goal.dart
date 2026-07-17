/// Goal-aware checks on generated dashboard HTML / Bro Code scripts.
///
/// Sandbox only proves QuickJS wrote an HTML vault key. This verifier catches
/// broken browser pages (dangling DOM refs) and unmet user goals (map/PWA/UI).
///
/// Acceptance uses HTML that [System.writeVault] will publish — not orphan
/// sidecar assets the execute() path never writes.
class BroCodeDashboardGoalResult {
  final bool ok;
  final List<String> findings;

  const BroCodeDashboardGoalResult({
    required this.ok,
    this.findings = const [],
  });
}

class BroCodeDashboardGoalChecker {
  BroCodeDashboardGoalChecker._();

  /// Extract HTML documents embedded in Bro Code (template literals or strings).
  static List<String> extractHtmlDocuments(String script) {
    final docs = <String>[];
    final doctype = RegExp(
      r'<!DOCTYPE\s+html[\s\S]*?</html\s*>',
      caseSensitive: false,
    );
    for (final m in doctype.allMatches(script)) {
      docs.add(_unescapeJsStringFragment(m.group(0)!));
    }
    if (docs.isEmpty) {
      // Fallback: any large chunk that looks like an HTML page.
      final loose = RegExp(
        r'<html[\s\S]*?</html\s*>',
        caseSensitive: false,
      );
      for (final m in loose.allMatches(script)) {
        docs.add(_unescapeJsStringFragment(m.group(0)!));
      }
    }
    return docs;
  }

  static String _unescapeJsStringFragment(String raw) {
    return raw
        .replaceAll(r'\`', '`')
        .replaceAll(r'\${', '\${')
        .replaceAll(r'\\n', '\n')
        .replaceAll(r'\\"', '"')
        .replaceAll(r"\\'", "'");
  }

  static bool looksLikeHtmlDocument(String text) {
    final t = text.trimLeft().toLowerCase();
    return t.startsWith('<!doctype html') ||
        t.startsWith('<html') ||
        t.contains('<!doctype html') ||
        RegExp(r'<html[\s>]', caseSensitive: false).hasMatch(t);
  }

  /// HTML bodies that `System.writeVault(...)` will actually publish.
  ///
  /// Resolves `System.assets['id']` and variables assigned to template/HTML
  /// strings. Orphan `*.html` assets that execute() never writes are ignored.
  static List<String> resolvePublishedHtmlDocuments(
    String script, {
    Map<String, String> assets = const {},
  }) {
    final out = <String>[];
    final seen = <String>{};

    void add(String? html) {
      if (html == null) return;
      final t = html.trim();
      if (t.isEmpty) return;
      if (seen.add(t)) out.add(t);
    }

    final callRe = RegExp(
      r'''System\.writeVault\s*\(\s*(['"])([^'"]*)\1\s*,\s*''',
      caseSensitive: false,
    );

    for (final m in callRe.allMatches(script)) {
      final key = m.group(2) ?? '';
      final valueExpr = _readJsArgument(script, m.end);
      if (valueExpr == null) continue;

      final keyLooksHtml = key.toLowerCase().endsWith('.html') ||
          key.toLowerCase().endsWith('.htm');

      final resolved = _resolveWriteVaultValue(
        script: script,
        valueExpr: valueExpr.trim(),
        assets: assets,
      );
      if (resolved != null) {
        if (looksLikeHtmlDocument(resolved) || keyLooksHtml) {
          add(resolved);
        }
        continue;
      }

      // Last resort: key suggests HTML and value is a bare asset id string.
      if (keyLooksHtml) {
        final lit = _parseJsStringLiteral(valueExpr.trim());
        if (lit != null && assets.containsKey(lit)) {
          add(assets[lit]);
        }
      }
    }

    return out;
  }

  static String? _resolveWriteVaultValue({
    required String script,
    required String valueExpr,
    required Map<String, String> assets,
  }) {
    final assetRef = RegExp(
      r'''^System\.assets\s*\[\s*(['"])([^'"]+)\1\s*\]\s*$''',
    ).firstMatch(valueExpr);
    if (assetRef != null) {
      return assets[assetRef.group(2)!];
    }

    final idMatch = RegExp(r'^([A-Za-z_$][\w$]*)$').firstMatch(valueExpr);
    if (idMatch != null) {
      final name = idMatch.group(1)!;
      final assignedAsset = RegExp(
        '(?:const|let|var)\\s+${RegExp.escape(name)}\\s*=\\s*'
        r'''System\.assets\s*\[\s*(['"])([^'"]+)\1\s*\]''',
      ).firstMatch(script);
      if (assignedAsset != null) {
        return assets[assignedAsset.group(2)!];
      }
      return extractAssignedHtmlString(script, name);
    }

    final inline = _parseJsStringLiteral(valueExpr);
    if (inline != null && looksLikeHtmlDocument(inline)) {
      return inline;
    }
    if (valueExpr.startsWith('`')) {
      final tpl = _readBacktickString(valueExpr);
      if (tpl != null) {
        final docs = extractHtmlDocuments(tpl);
        if (docs.isNotEmpty) return docs.first;
        if (looksLikeHtmlDocument(tpl)) {
          return _unescapeJsStringFragment(tpl);
        }
      }
    }
    return null;
  }

  /// Content of `const|let|var name = \`...\`` / string when it holds HTML.
  static String? extractAssignedHtmlString(String script, String varName) {
    final assignRe = RegExp(
      '(?:const|let|var)\\s+${RegExp.escape(varName)}\\s*=\\s*',
    );
    final m = assignRe.firstMatch(script);
    if (m == null) return null;
    final rest = script.substring(m.end).replaceFirst(RegExp(r'^\s*'), '');
    if (rest.startsWith('`')) {
      final tpl = _readBacktickString(rest);
      if (tpl == null) return null;
      final docs = extractHtmlDocuments(tpl);
      if (docs.isNotEmpty) return docs.first;
      return looksLikeHtmlDocument(tpl) ? _unescapeJsStringFragment(tpl) : null;
    }
    if (rest.startsWith("'") || rest.startsWith('"')) {
      final lit = _parseJsStringLiteral(rest);
      if (lit != null && looksLikeHtmlDocument(lit)) return lit;
    }
    return null;
  }

  /// Read one JS argument starting at [start] until a top-level comma / paren.
  static String? _readJsArgument(String source, int start) {
    if (start >= source.length) return null;
    final buf = StringBuffer();
    var i = start;
    var depthParen = 0;
    var depthBrace = 0;
    var depthBracket = 0;
    var depthTemplateExpr = 0;
    String? quote; // ' " or `
    var escaped = false;

    while (i < source.length) {
      final c = source[i];
      if (quote != null) {
        buf.write(c);
        if (escaped) {
          escaped = false;
          i++;
          continue;
        }
        if (c == '\\') {
          escaped = true;
          i++;
          continue;
        }
        if (quote == '`' && c == r'$' && i + 1 < source.length && source[i + 1] == '{') {
          depthTemplateExpr++;
          buf.write('{');
          i += 2;
          continue;
        }
        if (quote == '`' && c == '}' && depthTemplateExpr > 0) {
          depthTemplateExpr--;
          i++;
          continue;
        }
        if (c == quote && depthTemplateExpr == 0) {
          quote = null;
        }
        i++;
        continue;
      }

      if (c == "'" || c == '"' || c == '`') {
        quote = c;
        buf.write(c);
        i++;
        continue;
      }
      if (c == '(') depthParen++;
      if (c == ')') {
        if (depthParen == 0 && depthBrace == 0 && depthBracket == 0) {
          break;
        }
        depthParen--;
      }
      if (c == '{') depthBrace++;
      if (c == '}') depthBrace = depthBrace > 0 ? depthBrace - 1 : 0;
      if (c == '[') depthBracket++;
      if (c == ']') depthBracket = depthBracket > 0 ? depthBracket - 1 : 0;

      if (c == ',' && depthParen == 0 && depthBrace == 0 && depthBracket == 0) {
        break;
      }
      buf.write(c);
      i++;
    }

    final s = buf.toString().trim();
    return s.isEmpty ? null : s;
  }

  static String? _readBacktickString(String rest) {
    if (!rest.startsWith('`')) return null;
    final buf = StringBuffer();
    var i = 1;
    var depth = 0;
    while (i < rest.length) {
      final c = rest[i];
      if (c == '\\' && i + 1 < rest.length) {
        buf.write(rest[i + 1]);
        i += 2;
        continue;
      }
      if (c == '`' && depth == 0) return buf.toString();
      if (c == r'$' && i + 1 < rest.length && rest[i + 1] == '{') {
        depth++;
        buf.write(r'${');
        i += 2;
        continue;
      }
      if (c == '}' && depth > 0) {
        depth--;
        buf.write('}');
        i++;
        continue;
      }
      buf.write(c);
      i++;
    }
    return null;
  }

  static String? _parseJsStringLiteral(String expr) {
    final t = expr.trim();
    if (t.startsWith('`')) {
      final body = _readBacktickString(t);
      return body == null ? null : _unescapeJsStringFragment(body);
    }
    if (t.length < 2) return null;
    final q = t[0];
    if (q != "'" && q != '"') return null;
    final buf = StringBuffer();
    var escaped = false;
    for (var i = 1; i < t.length; i++) {
      final c = t[i];
      if (escaped) {
        buf.write(c);
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == q) return buf.toString();
      buf.write(c);
    }
    return null;
  }

  /// Collect element ids declared in HTML markup (id="…" / id='…').
  static Set<String> declaredElementIds(String html) {
    final ids = <String>{};
    final re = RegExp(
      r'''\bid\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final m in re.allMatches(html)) {
      ids.add(m.group(1)!);
    }
    return ids;
  }

  /// Ids referenced via getElementById('…') / getElementById("…").
  static Set<String> referencedElementIds(String html) {
    final ids = <String>{};
    final re = RegExp(
      r'''getElementById\s*\(\s*['"]([^'"]+)['"]\s*\)''',
    );
    for (final m in re.allMatches(html)) {
      ids.add(m.group(1)!);
    }
    return ids;
  }

  static BroCodeDashboardGoalResult checkDanglingDom(String html) {
    final declared = declaredElementIds(html);
    final referenced = referencedElementIds(html);
    final missing = referenced.difference(declared).toList()..sort();
    if (missing.isEmpty) {
      return const BroCodeDashboardGoalResult(ok: true);
    }
    return BroCodeDashboardGoalResult(
      ok: false,
      findings: missing
          .map(
            (id) =>
                'Dangling DOM reference: getElementById("$id") but no matching '
                'element id in HTML markup.',
          )
          .toList(),
    );
  }

  static bool looksLikeChartOrCanvas(String html) {
    final h = html.toLowerCase();
    return h.contains('<canvas') ||
        h.contains('getcontext(') ||
        h.contains('chart.js') ||
        h.contains('new chart(') ||
        RegExp(r'\bchart\b').hasMatch(h);
  }

  static bool looksLikeLeafletMap(String html) {
    final h = html.toLowerCase();
    return h.contains('leaflet') ||
        h.contains('l.map(') ||
        h.contains('openstreetmap') ||
        (h.contains('tile.openstreetmap') && h.contains('l.tilelayer'));
  }

  static bool looksLikeGoogleMaps(String html) {
    final h = html.toLowerCase();
    return h.contains('maps.googleapis.com') ||
        h.contains('google.maps') ||
        h.contains('new google.maps');
  }

  static bool wantsFromToDatetime(String changeRequest) {
    final r = changeRequest.toLowerCase();
    if (r.contains('datetime-local')) return true;
    final hasDatetime = r.contains('datetime') ||
        r.contains('date/time') ||
        r.contains('date-time') ||
        (r.contains('date') && r.contains('time') && r.contains('from'));
    return hasDatetime && r.contains('from') && r.contains('to');
  }

  static bool hasFromToDatetimeControls(String html) {
    final h = html.toLowerCase();
    if (h.contains('datetime-local')) return true;
    final dateInputs = RegExp(
      r'''type\s*=\s*["']date(?:time(?:-local)?)?["']''',
      caseSensitive: false,
    ).allMatches(html).length;
    if (dateInputs >= 2) return true;
    final hasFrom = RegExp(
      r'''\b(?:id|name)\s*=\s*["'][^"']*from[^"']*["']''',
      caseSensitive: false,
    ).hasMatch(html);
    final hasTo = RegExp(
      r'''\b(?:id|name)\s*=\s*["'][^"']*to[^"']*["']''',
      caseSensitive: false,
    ).hasMatch(html);
    return hasFrom &&
        hasTo &&
        (h.contains('type="date') ||
            h.contains("type='date") ||
            h.contains('datetime'));
  }

  /// True when the user asked for a range slider (not "instead of a slider").
  static bool wantsTimeSlider(String changeRequest) {
    final r = changeRequest.toLowerCase();
    if (!r.contains('slider')) return false;
    if (r.contains('instead of a slider') || r.contains('instead of slider')) {
      return false;
    }
    return true;
  }

  static bool hasRangeSlider(String html) {
    return RegExp(
      r'''type\s*=\s*["']range["']''',
      caseSensitive: false,
    ).hasMatch(html);
  }

  /// Mobile / installable PWA signals for vault dashboards.
  static BroCodeDashboardGoalResult checkPwa(String html, {Map<String, String>? assets}) {
    final findings = <String>[];
    final h = html.toLowerCase();

    if (!RegExp(
      r'''<meta[^>]+name\s*=\s*["']viewport["']''',
      caseSensitive: false,
    ).hasMatch(html)) {
      findings.add('PWA: missing <meta name="viewport" …>.');
    }
    if (!h.contains('rel="manifest"') && !h.contains("rel='manifest'")) {
      findings.add('PWA: missing <link rel="manifest" …>.');
    }
    if (!h.contains('serviceworker') && !h.contains('navigator.serviceworker')) {
      findings.add('PWA: missing service worker registration.');
    }
    if (!RegExp(
      r'''<meta[^>]+name\s*=\s*["']theme-color["']''',
      caseSensitive: false,
    ).hasMatch(html)) {
      findings.add('PWA: missing <meta name="theme-color" …>.');
    }
    if (!h.contains('apple-mobile-web-app') &&
        !h.contains('mobile-web-app-capable')) {
      findings.add(
        'PWA: missing mobile-web-app / apple-mobile-web-app capable meta.',
      );
    }

    if (assets != null) {
      final hasManifest = assets.keys.any(
        (k) => k.toLowerCase().endsWith('manifest.json') ||
            k.toLowerCase().contains('manifest'),
      );
      final hasSw = assets.keys.any(
        (k) =>
            k.toLowerCase().endsWith('sw.js') ||
            k.toLowerCase().contains('service-worker') ||
            k.toLowerCase().contains('serviceworker'),
      );
      if (!hasManifest && !h.contains('manifest')) {
        findings.add('PWA: no manifest asset or inline manifest link.');
      }
      if (!hasSw && !h.contains('serviceworker')) {
        findings.add('PWA: no service-worker asset or registration.');
      }
    }

    return BroCodeDashboardGoalResult(ok: findings.isEmpty, findings: findings);
  }

  /// Interpret [changeRequest] and validate HTML that execute() publishes.
  static BroCodeDashboardGoalResult checkAgainstChangeRequest({
    required String changeRequest,
    required String script,
    Map<String, String> assets = const {},
  }) {
    final published = resolvePublishedHtmlDocuments(script, assets: assets);
    final usedPublishedPath = published.isNotEmpty;
    final docs = usedPublishedPath
        ? published
        : <String>[
            ...extractHtmlDocuments(script),
            ...extractHtmlFromAssets(assets),
          ];

    if (docs.isEmpty) {
      if (!_changeTouchesDashboard(changeRequest)) {
        return const BroCodeDashboardGoalResult(ok: true);
      }
      return const BroCodeDashboardGoalResult(
        ok: false,
        findings: [
          'Change request affects a dashboard/UI, but no HTML document was '
              'found that System.writeVault publishes (embed HTML in execute() '
              'or writeVault from System.assets["…"]).',
        ],
      );
    }

    final findings = <String>[];
    final req = changeRequest.toLowerCase();

    // Orphan sidecar: HTML asset exists but is never published.
    if (usedPublishedPath) {
      final orphanHtmlAssets = assets.keys.where((k) {
        final kl = k.toLowerCase();
        if (!(kl.endsWith('.html') || kl.endsWith('.htm'))) return false;
        final content = assets[k]!;
        return !published.any((p) => p == content || p.trim() == content.trim());
      }).toList();
      if (orphanHtmlAssets.isNotEmpty &&
          _changeTouchesDashboard(changeRequest)) {
        // Only warn as finding when published HTML fails feature checks below;
        // surface a dedicated finding when datetime/slider asked and only orphan has it.
        if (wantsFromToDatetime(changeRequest) &&
            !docs.any(hasFromToDatetimeControls) &&
            orphanHtmlAssets.any((k) => hasFromToDatetimeControls(assets[k]!))) {
          findings.add(
            'From/to datetime controls exist only in unused asset(s) '
            '(${orphanHtmlAssets.join(', ')}), not in HTML that '
            'System.writeVault publishes. Wire execute() to '
            'writeVault(key, System.assets["…"], mime) or edit the published template.',
          );
        }
        if (wantsTimeSlider(changeRequest) &&
            !docs.any(hasRangeSlider) &&
            orphanHtmlAssets.any((k) => hasRangeSlider(assets[k]!))) {
          findings.add(
            'Range slider exists only in unused asset(s) '
            '(${orphanHtmlAssets.join(', ')}), not in published vault HTML.',
          );
        }
      }
    } else if (_changeTouchesDashboard(changeRequest) &&
        !script.contains('System.writeVault')) {
      findings.add(
        'Dashboard change request but execute() never calls System.writeVault '
        '— the browser will not receive updated HTML.',
      );
    }

    for (final html in docs) {
      final dangling = checkDanglingDom(html);
      if (!dangling.ok) findings.addAll(dangling.findings);

      final render = checkRenderableDashboardHtml(html, assets: assets);
      if (!render.ok) findings.addAll(render.findings);

      final removeChart = req.contains('remove') &&
          (req.contains('chart') ||
              req.contains('graph') ||
              req.contains('canvas') ||
              req.contains('device map'));
      final addMap = req.contains('map') &&
          (req.contains('leaflet') ||
              req.contains('google') ||
              req.contains('replace') ||
              req.contains('add'));
      final wantPwa = req.contains('pwa') ||
          req.contains('progressive web') ||
          req.contains('installable') ||
          req.contains('desktop dashboard');

      if (removeChart) {
        if (looksLikeChartOrCanvas(html)) {
          findings.add(
            'Change requested chart/canvas removal, but HTML still contains '
            'canvas/chart code.',
          );
        }
      }

      if (addMap ||
          (req.contains('leaflet') || req.contains('google map'))) {
        final hasLeaflet = looksLikeLeafletMap(html);
        final hasGoogle = looksLikeGoogleMaps(html);
        if (!hasLeaflet && !hasGoogle) {
          findings.add(
            'Change requested a map (Leaflet/Google), but HTML has no Leaflet '
            'or Google Maps integration.',
          );
        }
        if (req.contains('leaflet') && !hasLeaflet && hasGoogle) {
          findings.add(
            'Change requested Leaflet; prefer OpenStreetMap/Leaflet over Google '
            'Maps (no API key).',
          );
        }
      }

      if (wantPwa) {
        final pwa = checkPwa(html, assets: assets);
        if (!pwa.ok) findings.addAll(pwa.findings);
      }

      if (wantsFromToDatetime(changeRequest) &&
          !hasFromToDatetimeControls(html)) {
        findings.add(
          'Change requested from/to datetime inputs, but published HTML has no '
          'datetime-local (or equivalent from/to date) controls.',
        );
      }

      if (wantsTimeSlider(changeRequest) && !hasRangeSlider(html)) {
        findings.add(
          'Change requested a time-range slider, but published HTML has no '
          '<input type="range"> control.',
        );
      }
    }

    return BroCodeDashboardGoalResult(
      ok: findings.isEmpty,
      findings: findings,
    );
  }

  /// Collect HTML documents from sidecar assets (`*.html` / text that looks like HTML).
  static List<String> extractHtmlFromAssets(Map<String, String> assets) {
    final docs = <String>[];
    for (final entry in assets.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value;
      if (key.endsWith('.html') ||
          key.endsWith('.htm') ||
          value.trimLeft().toLowerCase().startsWith('<!doctype html') ||
          value.trimLeft().toLowerCase().startsWith('<html')) {
        final fromAsset = extractHtmlDocuments(value);
        if (fromAsset.isNotEmpty) {
          docs.addAll(fromAsset);
        } else {
          docs.add(value);
        }
      }
    }
    return docs;
  }

  /// Structural checks so IMPROVE cannot go green on HTML that paints blank.
  ///
  /// Catches empty bodies, missing UI chrome, unguarded Leaflet CDN use, and
  /// serviceWorker.register without a published SW asset (SW can blank the origin).
  static BroCodeDashboardGoalResult checkRenderableDashboardHtml(
    String html, {
    Map<String, String> assets = const {},
  }) {
    final findings = <String>[];
    final t = html.trim();
    if (t.length < 80) {
      findings.add(
        'Published HTML is too short (${t.length} chars) — browser would show '
        'a blank page.',
      );
      return BroCodeDashboardGoalResult(ok: false, findings: findings);
    }
    if (!RegExp(r'<body[\s>]', caseSensitive: false).hasMatch(t)) {
      findings.add('Published HTML has no <body> — cannot render a dashboard.');
    }

    final hasVisibleUi = RegExp(
      r'''<(input|button|canvas|svg|img|table|h[1-6]\b)|id\s*=\s*["']map["']''',
      caseSensitive: false,
    ).hasMatch(t);
    if (!hasVisibleUi) {
      findings.add(
        'Published HTML has no obvious visible UI (controls/map/content) — '
        'risk of a blank white page.',
      );
    }

    final usesLeafletApi =
        RegExp(r'\bL\.(map|tileLayer|marker|polyline)\b').hasMatch(t);
    final guardsLeaflet = RegExp(
      r'''typeof\s+L\s*(!==?|===?)\s*['"]undefined['"]|if\s*\(\s*typeof\s+L\b''',
    ).hasMatch(t);
    if (usesLeafletApi && !guardsLeaflet) {
      findings.add(
        'Leaflet API (L.map/…) runs without a typeof L guard. If the CDN script '
        'fails (offline/blocked), the page JS dies — wrap map init in '
        '`if (typeof L !== "undefined") { … } else { show error }`.',
      );
    }

    final swReg = RegExp(
      r'''navigator\.serviceWorker\.register\s*\(\s*(['"])([^'"]+)\1''',
      caseSensitive: false,
    ).firstMatch(t);
    if (swReg != null) {
      final swPath = swReg.group(2) ?? '';
      final swName = swPath.split('/').where((s) => s.isNotEmpty).last;
      final hasSwAsset = assets.keys.any((k) {
        final kl = k.toLowerCase();
        return kl == swName.toLowerCase() ||
            kl.endsWith('/${swName.toLowerCase()}') ||
            kl.endsWith('.sw.js') ||
            kl.contains('service-worker') ||
            kl.contains('serviceworker');
      });
      if (!hasSwAsset) {
        findings.add(
          'HTML registers serviceWorker("$swPath") but no matching SW asset is '
          'published (e.g. sw.js). A missing/broken SW with broad scope can '
          'blank every page on the edge-server origin — publish the SW or '
          'remove the register() call.',
        );
      }
    }

    final unbounded = checkUnboundedTelemetryQueries(html);
    if (!unbounded.ok) findings.addAll(unbounded.findings);

    return BroCodeDashboardGoalResult(
      ok: findings.isEmpty,
      findings: findings,
    );
  }

  /// Fails row-returning telemetry SELECTs that omit LIMIT (heavy dashboards).
  ///
  /// Aggregates (COUNT/SUM/AVG/MIN/MAX without selecting raw rows) are allowed.
  static BroCodeDashboardGoalResult checkUnboundedTelemetryQueries(String html) {
    final findings = <String>[];
    final sqlLiterals = <String>[];

    // JSON body: {"sql":"SELECT ..."} or {'sql':'...'}
    final jsonSql = RegExp(
      r'''["']sql["']\s*:\s*["'`]([^"'`]+)["'`]''',
      caseSensitive: false,
    );
    for (final m in jsonSql.allMatches(html)) {
      sqlLiterals.add(m.group(1)!);
    }

    // Template / string literals that look like SELECT … FROM telemetry
    final selectSql = RegExp(
      r'''[`'"]\s*(SELECT\b[^`'"]*?FROM\s+telemetry[^`'"]*)[`'"]''',
      caseSensitive: false,
    );
    for (final m in selectSql.allMatches(html)) {
      sqlLiterals.add(m.group(1)!);
    }

    final seen = <String>{};
    for (final raw in sqlLiterals) {
      final sql = raw.replaceAll(r'\n', ' ').trim();
      if (sql.isEmpty || !seen.add(sql.toLowerCase())) continue;
      if (!_isTelemetrySelect(sql)) continue;
      if (_isAggregateOnlySelect(sql)) continue;
      if (RegExp(r'\bLIMIT\b', caseSensitive: false).hasMatch(sql)) continue;
      findings.add(
        'Telemetry SELECT lacks LIMIT (risk of loading all rows into the browser): '
        '"${sql.length > 120 ? '${sql.substring(0, 120)}…' : sql}". '
        'Add LIMIT (and OFFSET / Prev-Next for tables) or downsample map points.',
      );
    }

    return BroCodeDashboardGoalResult(
      ok: findings.isEmpty,
      findings: findings,
    );
  }

  static bool _isTelemetrySelect(String sql) {
    final s = sql.toLowerCase();
    return s.contains('select') &&
        RegExp(r'\bfrom\s+telemetry\b').hasMatch(s);
  }

  /// COUNT/SUM/… only — no raw column list that would dump every row.
  static bool _isAggregateOnlySelect(String sql) {
    final s = sql.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final m = RegExp(r'select\s+(.+?)\s+from\s+telemetry\b').firstMatch(s);
    if (m == null) return false;
    final projection = m.group(1)!;
    if (RegExp(r'(^|,)\s*\*\s*(,|$)').hasMatch(projection)) return false;
    // Strip aggregates (incl. COUNT(*)) and optional AS aliases; nothing raw left.
    final withoutAggs = projection.replaceAll(
      RegExp(r'\b(count|sum|avg|min|max)\s*\([^)]*\)(\s+as\s+[a-z_][\w]*)?'),
      '',
    );
    return RegExp(r'^[\s,]*$').hasMatch(withoutAggs);
  }

  static bool _changeTouchesDashboard(String change) {
    final c = change.toLowerCase();
    return c.contains('dashboard') ||
        c.contains('html') ||
        c.contains('chart') ||
        c.contains('graph') ||
        c.contains('canvas') ||
        c.contains('map') ||
        c.contains('pwa') ||
        c.contains('progressive') ||
        c.contains('locator') ||
        c.contains('leaflet') ||
        c.contains('slider') ||
        c.contains('datetime') ||
        (c.contains('from') && c.contains('to') && c.contains('date'));
  }
}
