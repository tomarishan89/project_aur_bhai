/// Canonical System-bridge protocol text injected into LLM author/refine prompts.
///
/// Keep this in sync with [JsBridgeService] and `examples/TelemetryDashboard.js`.
class AgentBridgeSpec {
  AgentBridgeSpec._();

  /// Short blurb for conversational slot-filling (parseTurn App Spec).
  static const String slotFillingHint = '''
Sandbox reality (when filling dataSources / outputs):
- Agents run in QuickJS with ONLY System.querySQL (SELECT), System.writeVault,
  System.sendHTTP, and System.log — no browser DOM, fetch, require, or fs in execute().
- Dashboards: write self-contained HTML via System.writeVault; the HTML (not execute)
  may use fetch('/api/query') and document.* because it runs in the WebView.
- Telemetry table: telemetry(id, timestamp, latitude, longitude, accelerometerZ, compassDirection).
''';

  /// Full protocol for authorAgent / refineAgentScript compilers.
  static const String bridgeSpecForLlm = '''
The agent runs in a sandboxed QuickJS runtime. ONLY this System bridge is available
in execute() — there is no browser, Node, require, import, fetch, fs, or DOM:

  System.querySQL(sqlString)              // READ-ONLY SELECT. Returns array of row objects (await).
  System.writeVault(key, value, mimeType) // Persist a string asset (e.g. HTML). Await it.
  System.sendHTTP(url, payload)           // GET if payload is null, else POST JSON. Returns {statusCode, body}. Await.
  System.log(message)                     // Emit a step log to the execution console.

HARD REQUIREMENTS:
- Define exactly: async function execute(params) { ... }
- execute MUST return a short, human-readable sentence for text-to-speech.
- Use ONLY the System bridge above inside execute().
- SQL is SQLite. Telemetry schema:
    telemetry(id TEXT, timestamp TEXT, latitude REAL, longitude REAL, accelerometerZ REAL, compassDirection REAL)
- If building a UI/dashboard: write a COMPLETE self-contained HTML string to the vault via
  System.writeVault('<key>.html', html, 'text/html'). Inside that HTML (browser context only),
  fetch data from SAME-ORIGIN POST /api/query with body {"sql":"SELECT ..."} using inline
  <script> and <style> (no external CDNs). document/fetch in the HTML template is OK;
  they must NOT appear as live QuickJS calls outside the template string.
- Spoken return should direct users to the Vault Dashboards panel — not a bare /vault/ path.
- Never hardcode API secrets; use Settings BYOK keys with System.sendHTTP when needed.

KNOWN-GOOD SHAPE (abbreviated — follow this pattern for dashboards):
async function execute(params) {
  System.log('composing dashboard');
  const html = `<!DOCTYPE html><html><body>
  <div id="c">…</div>
  <script>
    fetch('/api/query', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({sql:'SELECT COUNT(*) AS c FROM telemetry'})})
      .then(r => r.json()).then(j => { document.getElementById('c').textContent = j.data[0].c; });
  </script>
  </body></html>`;
  await System.writeVault('MyDashboard.html', html, 'text/html');
  return 'Dashboard ready. Open it from the Vault Dashboards panel on the Agents page.';
}
''';

  /// Authoring (create new agent): full source via Base64.
  static const String authorOutputTransport = '''
OUTPUT TRANSPORT (new agents): put the FULL JavaScript source in "scriptBase64"
(standard Base64 of the UTF-8 source). Do NOT put raw JS/HTML inside a JSON "script"
string — large dashboard templates truncate and break JSON.
''';

  /// Refine / IMPROVE: prefer a complete script rewrite (Coder Agent).
  /// Surgical edits remain a last-resort fallback.
  static const String refineOutputTransport = '''
OUTPUT TRANSPORT (Bro Code refine — Coder Agent):
Return the FULL JavaScript source in "scriptBase64" (standard Base64 of UTF-8).
Do NOT rely on surgical search/replace patches — they fail on large templates.

Respond ONLY in RAW JSON:
{
  "name": "<same name>",
  "description": "updated one-line description",
  "inputSchema": { },
  "scriptBase64": "BASE64 of the complete javascript UTF-8 source",
  "notes": "what changed"
}

Rules:
- Preserve unrelated behavior; apply the USER CHANGE REQUEST completely.
- Ensure valid QuickJS syntax and async function execute(params).
- Dashboard HTML stays inside the JS template string; Base64 the whole file once.
- Optional legacy: tiny "edits"[] arrays are accepted only when the Bro Code is
  under ~2KB and a one-line fix is clearer than a rewrite.
''';

  /// Shown when refine JSON cannot be parsed.
  static const String invalidPatchJsonUserMessage =
      'Model returned invalid Bro Code JSON (often unescaped quotes in script text). '
      'Retry — the Coder Agent expects scriptBase64 for the full source.';

  /// @Deprecated Prefer [invalidPatchJsonUserMessage].
  static const String incompleteJsonUserMessage = invalidPatchJsonUserMessage;
}
