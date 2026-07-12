// TelemetryDashboard.js  —  Reference JS agent for Project Aur Bhai
// ---------------------------------------------------------------------------
// MS-TELEMETRY-DASHBOARD (Path B reference — documentation only, NOT bundled in APK).
//
// HOW TO USE (Path B — no LLM required):
//   1. Open the app → Agents page (right tab) → CREATE AGENT → MANUAL IMPORT.
//   2. Name: TelemetryDashboard   (leave schema empty)
//   3. Paste this entire file into the "JavaScript source" box.
//   4. Security class: your choice (C3 recommended).  Save & Register.
//   5. Tap the agent card → RUN.  It writes an HTML dashboard into the vault.
//   6. Back on the Agents page → VAULT DASHBOARDS → open "telemetry_dashboard.html".
//
// HOW TO USE (Path A — LLM authoring):
//   Agents page → CREATE AGENT → AI AUTHORING → describe:
//   "Build a live telemetry dashboard that charts accelerometer Z over time
//    from the local SQLite vault." The model will produce an agent like this.
//
// The System bridge available inside the sandbox:
//   System.querySQL(sql)                 -> await, read-only SELECT, returns rows[]
//   System.writeVault(key, value, mime)  -> await, persists a string asset
//   System.sendHTTP(url, payload)        -> await, GET/POST
//   System.log(msg)                      -> execution console log
//
// The dashboard HTML is fully self-contained (no external CDNs — the device may
// be offline) and fetches live data from the SAME-ORIGIN edge endpoint
//   POST /api/query   body: {"sql": "SELECT ..."}
// which is served by the local Shelf edge server.
// ---------------------------------------------------------------------------

async function execute(params) {
  System.log('TelemetryDashboard: composing self-contained HTML dashboard');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Aur Bhai — Telemetry Dashboard</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #0b0b0b; color: #eaeaea;
         font-family: -apple-system, Segoe UI, Roboto, sans-serif; }
  header { padding: 16px 20px; border-bottom: 1px solid #1e1e1e; }
  h1 { margin: 0; font-size: 16px; letter-spacing: 1px; }
  .sub { color: #6be675; font-size: 12px; margin-top: 4px; }
  .cards { display: flex; gap: 12px; padding: 16px 20px; flex-wrap: wrap; }
  .card { background: #151515; border: 1px solid #222; border-radius: 12px;
          padding: 14px 18px; min-width: 120px; }
  .card .k { color: #888; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; }
  .card .v { color: #fff; font-size: 22px; font-weight: 700; margin-top: 6px; }
  .chartwrap { padding: 0 20px 24px; }
  canvas { width: 100%; height: 260px; background: #101010;
           border: 1px solid #222; border-radius: 12px; }
  footer { color: #555; font-size: 10px; padding: 0 20px 24px; font-family: monospace; }
</style>
</head>
<body>
  <header>
    <h1>PROJECT AUR BHAI — TELEMETRY</h1>
    <div class="sub" id="status">Connecting to sovereign vault…</div>
  </header>
  <div class="cards">
    <div class="card"><div class="k">Records</div><div class="v" id="count">–</div></div>
    <div class="card"><div class="k">Latest Accel Z</div><div class="v" id="latest">–</div></div>
    <div class="card"><div class="k">Avg Accel Z (50)</div><div class="v" id="avg">–</div></div>
  </div>
  <div class="chartwrap"><canvas id="chart"></canvas></div>
  <footer id="ts"></footer>
<script>
  async function query(sql) {
    const r = await fetch('/api/query', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sql: sql })
    });
    const j = await r.json();
    if (!j.success) throw new Error(j.error || 'query failed');
    return j.data;
  }

  function drawChart(values) {
    const c = document.getElementById('chart');
    const dpr = window.devicePixelRatio || 1;
    c.width = c.clientWidth * dpr; c.height = c.clientHeight * dpr;
    const ctx = c.getContext('2d');
    ctx.scale(dpr, dpr);
    const W = c.clientWidth, H = c.clientHeight, pad = 24;
    ctx.clearRect(0, 0, W, H);
    if (!values.length) return;
    const min = Math.min.apply(null, values), max = Math.max.apply(null, values);
    const span = (max - min) || 1;
    ctx.strokeStyle = '#6be675'; ctx.lineWidth = 2; ctx.beginPath();
    values.forEach(function (v, i) {
      const x = pad + (W - 2 * pad) * (i / Math.max(1, values.length - 1));
      const y = H - pad - (H - 2 * pad) * ((v - min) / span);
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });
    ctx.stroke();
    ctx.fillStyle = '#555'; ctx.font = '10px monospace';
    ctx.fillText(max.toFixed(2), 2, pad);
    ctx.fillText(min.toFixed(2), 2, H - pad + 8);
  }

  async function refresh() {
    try {
      const countRows = await query('SELECT COUNT(*) AS c FROM telemetry');
      const rows = await query('SELECT accelerometerZ FROM telemetry ORDER BY timestamp DESC LIMIT 50');
      const series = rows.map(function (r) { return r.accelerometerZ; }).reverse();
      const count = countRows[0] ? countRows[0].c : 0;
      const latest = series.length ? series[series.length - 1] : null;
      const avg = series.length ? series.reduce(function (a, b) { return a + b; }, 0) / series.length : null;

      document.getElementById('count').textContent = count;
      document.getElementById('latest').textContent = latest != null ? latest.toFixed(2) : '–';
      document.getElementById('avg').textContent = avg != null ? avg.toFixed(2) : '–';
      document.getElementById('status').textContent = 'Live · sovereign SQLite vault · same-origin';
      document.getElementById('ts').textContent = 'last refresh: ' + new Date().toISOString();
      drawChart(series);
    } catch (e) {
      document.getElementById('status').textContent = 'Error: ' + e.message;
    }
  }

  refresh();
  setInterval(refresh, 3000);
</script>
</body>
</html>`;

  await System.writeVault('telemetry_dashboard.html', html, 'text/html');
  System.log('TelemetryDashboard: HTML written to vault key telemetry_dashboard.html');
  return 'Telemetry dashboard is ready. Open /vault/telemetry_dashboard.html from the Agents page to see live accelerometer charts.';
}
