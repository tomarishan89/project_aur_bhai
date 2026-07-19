/// Canonical System-bridge protocol text injected into LLM author/refine prompts.
///
/// Keep this in sync with [JsBridgeService] and `examples/TelemetryDashboard.js`.
class AgentBridgeSpec {
  AgentBridgeSpec._();

  /// Short blurb for conversational slot-filling (parseTurn App Spec).
  static const String slotFillingHint = '''
Sandbox reality (when filling dataSources / outputs):
- Agents run in QuickJS with ONLY System.querySQL (SELECT), System.writeVault,
  System.sendHTTP, System.readInbox / System.consumeInbox, System.notifyUser,
  and System.log — no browser DOM, fetch, require, or fs in execute().
- Dashboards: write self-contained HTML via System.writeVault; the HTML (not execute)
  may use fetch('/api/query') and document.* because it runs in the WebView.
- Telemetry table: telemetry(id, timestamp, latitude, longitude, accelerometerZ, compassDirection).
- Assume large data: dashboards MUST paginate / LIMIT queries (never unbounded SELECT *).
''';

  /// Full protocol for authorAgent / refineAgentScript compilers.
  static const String bridgeSpecForLlm = '''
The agent runs in a sandboxed QuickJS runtime. ONLY this System bridge is available
in execute() — there is no browser, Node, require, import, fetch, fs, or DOM:

  System.querySQL(sqlString)              // READ-ONLY SELECT. Returns array of row objects (await).
  System.writeVault(key, value, mimeType) // Persist a string asset (e.g. HTML). Await it.
  System.sendHTTP(url, payload)           // GET if payload is null, else POST JSON. Returns {statusCode, body}. Await.
  System.readInbox({ unreadOnly, limit }) // Voice/"Tell" inbox entries for this agent (await).
  System.consumeInbox({ ids })            // Mark inbox entries consumed (await).
  System.notifyUser({ title, body, speakText }) // Queue a Bro Call (local notification + Aur Bhai cue). Await.
  System.log(message)                     // Emit a step log to the execution console.
  System.assets                           // Read-only map of sidecar strings (HTML/manifest/SW) injected by the host.

HARD REQUIREMENTS:
- Define exactly: async function execute(params) { ... }
- execute MUST return a short, human-readable sentence for text-to-speech.
- Use ONLY the System bridge above inside execute().
- SQL is SQLite. Telemetry schema:
    telemetry(id TEXT, timestamp TEXT, latitude REAL, longitude REAL, accelerometerZ REAL, compassDirection REAL)
- Prefer thin orchestrators: keep large dashboard HTML / PWA manifest / service worker in
  host sidecars and publish via System.writeVault(key, System.assets['id'], mime). Prefer
  this over embedding multi-KB HTML inside the execute template. Nested backticks inside
  HTML template literals break QuickJS syntax — use System.assets instead. Host IMPROVE
  goals judge only HTML that writeVault publishes — unused sidecar files do not count.
- PLATFORM WIRING (every Bro Code, not just dashboards): every System.assets['id'] must
  exist; publishable sidecars must be referenced by execute(); do not leave dead code after
  return. Host may auto-repair half-thin / orphan-asset wiring.
- If building a UI/dashboard without sidecars yet: still prefer extracting HTML to an asset
  on the next edit. Until then, a COMPLETE self-contained HTML string via
  System.writeVault('<key>.html', html, 'text/html') is allowed. Inside that HTML (browser
  only), fetch from SAME-ORIGIN POST /api/query with body {"sql":"SELECT ..."} using inline
  <script> and <style>. Prefer Leaflet + OpenStreetMap tiles (no Google Maps API key)
  unless the user insists on Google Maps. Escape any inner backticks (\\`) if HTML must
  stay in a JS template literal.
- Progressive Web App (when requested / "feels like a desktop dashboard on mobile"): include
  <meta name="viewport" …>, <meta name="theme-color" …>, mobile-web-app-capable /
  apple-mobile-web-app-capable, <link rel="manifest" href="/vault/<name>.webmanifest">,
  and register a service worker (navigator.serviceWorker.register('/vault/<name>.sw.js')).
  Write the manifest (application/manifest+json) and SW (application/javascript) via
  System.writeVault (from System.assets when available). Same-device installability needs
  localhost / HTTPS secure context — LAN-IP HTTP is fine for viewing but not for full PWA install.
- Spoken return should direct users to the Vault Dashboards panel — not a bare /vault/ path.
- document/fetch/window in the HTML template is OK; they must NOT appear as live QuickJS
  calls outside the template string.
- Never hardcode API secrets; use Settings BYOK keys with System.sendHTTP when needed.
- DATA VOLUME & PERFORMANCE (mandatory for every dashboard — users will not ask for this):
  Telemetry and vault tables grow large. NEVER SELECT * / unbounded row dumps into the
  browser. Every row-returning SQL via System.querySQL or fetch('/api/query') MUST include
  a SQLite LIMIT (typical: 50–200 for tables; ≤500 downsampled points for maps/polylines).
  Prefer LIMIT + OFFSET (or keyset) pagination with Prev/Next (or Load more) controls for
  HTML tables. For maps/charts: default to recent window (ORDER BY timestamp DESC LIMIT N)
  and/or coarse downsampling — do not plot every raw point. Aggregates (COUNT/SUM/AVG
  without a raw row list) may omit LIMIT. Host IMPROVE fails unbounded telemetry SELECTs.

KNOWN-GOOD SHAPE (abbreviated — follow this pattern for dashboards):
async function execute(params) {
  System.log('composing dashboard');
  const html = System.assets['MyDashboard.html'];
  await System.writeVault('MyDashboard.html', html, 'text/html');
  return 'Dashboard ready. Open it from the Vault Dashboards panel on the Agents page.';
}
''';

  /// Authoring (create new agent): full source via Base64; large HTML as assets.
  static const String authorOutputTransport = '''
OUTPUT TRANSPORT (new agents):
- Put the execute() JavaScript in "scriptBase64" (Base64 of UTF-8). Do NOT put
  raw JS/HTML inside a JSON "script" string — large payloads truncate and break JSON.
- Prefer a thin orchestrator. Put large dashboard HTML / PWA manifest / service
  worker in optional "assets": { "<id>.html": "...", ... } (or Base64 per asset)
  and publish with System.writeVault(key, System.assets['id'], mime).
- Do NOT nest multi-KB dashboard HTML inside the execute() template string when
  you can use System.assets sidecars instead.
''';

  /// Refine / IMPROVE: prefer assets + surgical edits; full rewrite of thin execute only.
  static const String refineOutputTransport = '''
OUTPUT TRANSPORT (Bro Code refine — Coder Agent):
Prefer thin execute() + System.assets sidecars for HTML / manifest / service worker.
Do NOT keep dashboard HTML inside the JS template string when assets can hold it.

Respond ONLY in RAW JSON. Preferred shapes:
1) Surgical: {"edits":[{"oldStringBase64":"...","newStringBase64":"...","asset":"<id>?"}]}
2) Thin orchestrator rewrite: {"scriptBase64":"BASE64 of execute() only","notes":"..."}
   plus optional "assets" / asset edits for HTML/PWA — not nested in the script.
3) Full scriptBase64 alone only when there are no assets and the Bro Code is small.

Rules:
- Preserve unrelated behavior; apply the USER CHANGE REQUEST completely.
- Ensure valid QuickJS syntax and async function execute(params).
- Put large HTML/manifest/SW in assets; execute() should System.writeVault from
  System.assets when available. Avoid nested backticks inside HTML template literals.
- Prefer apply_edit / edits[] when Assets are listed; do not rewrite the whole
  execute script for HTML-only changes.
''';

  /// Shown when refine JSON cannot be parsed.
  static const String invalidPatchJsonUserMessage =
      'Model returned invalid Bro Code JSON (often unescaped quotes or truncated HTML). '
      'Retry — prefer thin scriptBase64 plus assets, or surgical edits on assets.';

  /// @Deprecated Prefer [invalidPatchJsonUserMessage].
  static const String incompleteJsonUserMessage = invalidPatchJsonUserMessage;
}
