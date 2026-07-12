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
- When returning JSON, escape the script string correctly (quotes, newlines, backticks).

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
}
