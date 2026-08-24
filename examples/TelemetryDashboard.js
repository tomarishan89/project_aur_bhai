// Telemeter.js — Advanced PWA Telemetry Dashboard for Project Aur Bhai
// ---------------------------------------------------------------------------
// NAME: Telemeter
// VOICE INVOCATION: "Ask Telemeter", "Ask Telemeter to show telemetry"
// VAULT KEYS: telemeter.html, telemetry_dashboard.html
// URL: http://localhost:8080/vault/telemeter.html
// ---------------------------------------------------------------------------

async function execute(params) {
  System.log('Telemeter: generating PWA Telemetry Dashboard HTML...');

  const html = `<!DOCTYPE html>
<html lang="en" data-theme="cyber">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<title>Telemeter — Sovereign Telemetry Dashboard</title>
<link rel="manifest" href="data:application/manifest+json;charset=utf-8,%7B%22name%22%3A%22Telemeter%22%2C%22short_name%22%3A%22Telemeter%22%2C%22start_url%22%3A%22%2Fvault%2Ftelemeter.html%22%2C%22display%22%3A%22standalone%22%2C%22background_color%22%3A%22%230f172a%22%2C%22theme_color%22%3A%22%2306b6d4%22%7D" />
<meta name="theme-color" content="#06b6d4" />
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="" />
<style>
  :root[data-theme="cyber"] {
    --bg-main: #0f172a; --bg-card: #1e293b; --bg-card-border: #334155;
    --text-primary: #f8fafc; --text-secondary: #94a3b8; --accent: #06b6d4;
    --accent-glow: rgba(6, 182, 212, 0.25); --accent-sec: #10b981; --grid-line: #334155;
  }
  :root[data-theme="oled"] {
    --bg-main: #000000; --bg-card: #111111; --bg-card-border: #222222;
    --text-primary: #ffffff; --text-secondary: #888888; --accent: #6366f1;
    --accent-glow: rgba(99, 102, 241, 0.25); --accent-sec: #f59e0b; --grid-line: #222222;
  }
  :root[data-theme="light"] {
    --bg-main: #f8fafc; --bg-card: #ffffff; --bg-card-border: #e2e8f0;
    --text-primary: #0f172a; --text-secondary: #64748b; --accent: #2563eb;
    --accent-glow: rgba(37, 99, 235, 0.15); --accent-sec: #e11d48; --grid-line: #e2e8f0;
  }
  :root[data-theme="nordic"] {
    --bg-main: #1e1e2e; --bg-card: #2b2b3d; --bg-card-border: #3b3b4f;
    --text-primary: #cdd6f4; --text-secondary: #a6adc8; --accent: #89dceb;
    --accent-glow: rgba(137, 220, 235, 0.2); --accent-sec: #f38ba8; --grid-line: #3b3b4f;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  body { background: var(--bg-main); color: var(--text-primary); min-height: 100vh; display: flex; flex-direction: column; overflow-x: hidden; }

  header {
    background: var(--bg-card); border-bottom: 1px solid var(--bg-card-border);
    padding: 8px 12px; display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap;
  }
  .brand { display: flex; align-items: center; gap: 8px; }
  .brand-logo { width: 28px; height: 28px; background: var(--accent); border-radius: 6px; display: grid; place-content: center; font-weight: 900; color: #fff; font-size: 14px; }
  .brand-title h1 { font-size: 14px; letter-spacing: 0.5px; }
  .brand-title .sub { font-size: 10px; color: var(--accent-sec); display: flex; align-items: center; gap: 4px; }
  .live-dot { width: 6px; height: 6px; background: var(--accent-sec); border-radius: 50%; display: inline-block; animation: pulse 1.5s infinite; }

  @keyframes pulse { 0% { opacity: 0.4; } 50% { opacity: 1; } 100% { opacity: 0.4; } }

  .header-controls { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .btn {
    background: var(--bg-card); border: 1px solid var(--bg-card-border); color: var(--text-primary);
    padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: 600; cursor: pointer;
    display: inline-flex; align-items: center; gap: 4px; transition: all 0.2s ease;
  }
  .btn:hover { border-color: var(--accent); color: var(--accent); }
  .btn-accent { background: var(--accent); color: #fff; border: none; }
  select.btn { outline: none; }

  .kpi-bar {
    display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; padding: 8px 12px;
  }
  @media (min-width: 600px) {
    .kpi-bar { grid-template-columns: repeat(5, 1fr); }
  }
  .kpi-card {
    background: var(--bg-card); border: 1px solid var(--bg-card-border); border-radius: 8px; padding: 8px 10px;
  }
  .kpi-label { font-size: 9px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--text-secondary); }
  .kpi-val { font-size: 16px; font-weight: 800; color: var(--text-primary); margin-top: 2px; }
  .kpi-unit { font-size: 10px; font-weight: 400; color: var(--text-secondary); margin-left: 2px; }

  .main-grid {
    display: grid; grid-template-columns: 1fr; gap: 10px; padding: 0 12px 12px; flex: 1;
  }
  @media (min-width: 850px) {
    .main-grid { grid-template-columns: 1fr 340px; }
  }

  .charts-pane { display: flex; flex-direction: column; gap: 10px; }
  .card-pane {
    background: var(--bg-card); border: 1px solid var(--bg-card-border); border-radius: 10px; padding: 10px;
    display: flex; flex-direction: column; gap: 6px;
  }
  .card-header { display: flex; justify-content: space-between; align-items: center; }
  .card-title { font-size: 11px; font-weight: 700; color: var(--text-primary); text-transform: uppercase; letter-spacing: 0.5px; }

  .canvas-wrap { position: relative; width: 100%; height: 180px; }
  @media (min-width: 600px) { .canvas-wrap { height: 220px; } }
  canvas { width: 100%; height: 100%; display: block; border-radius: 6px; }

  .time-slider-wrap { display: flex; flex-direction: column; gap: 4px; margin-top: 4px; }
  .time-labels { display: flex; justify-content: space-between; font-size: 10px; color: var(--text-secondary); font-family: monospace; }
  input[type="range"] { width: 100%; accent-color: var(--accent); cursor: pointer; height: 14px; }

  .map-pane { height: 220px; position: relative; border-radius: 10px; overflow: hidden; border: 1px solid var(--bg-card-border); }
  @media (min-width: 850px) { .map-pane { height: 100%; min-height: 320px; } }
  #map { width: 100%; height: 100%; min-height: 220px; }

  .drawer {
    background: var(--bg-card); border-top: 1px solid var(--bg-card-border);
    transition: transform 0.3s ease; max-height: 240px; overflow-y: auto; padding: 8px 12px;
  }
  .drawer.collapsed { display: none; }
  table { width: 100%; border-collapse: collapse; font-size: 11px; text-align: left; }
  th, td { padding: 6px 8px; border-bottom: 1px solid var(--bg-card-border); }
  th { color: var(--text-secondary); font-weight: 600; text-transform: uppercase; font-size: 9px; }

  /* Modal */
  .modal-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.6); backdrop-filter: blur(4px);
    display: none; place-content: center; z-index: 9999;
  }
  .modal-overlay.active { display: grid; }
  .modal {
    background: var(--bg-card); border: 1px solid var(--bg-card-border); border-radius: 14px;
    padding: 20px; width: 90%; max-width: 400px; display: flex; flex-direction: column; gap: 14px;
  }
  .modal-title { font-size: 15px; font-weight: 700; }
  .modal-options { display: flex; flex-direction: column; gap: 8px; }
  .radio-opt { display: flex; align-items: center; gap: 8px; font-size: 12px; cursor: pointer; }
</style>
</head>
<body>

  <header>
    <div class="brand">
      <div class="brand-logo">T</div>
      <div class="brand-title">
        <h1>TELEMETER</h1>
        <div class="sub" id="status-indicator"><span class="live-dot"></span> Vault Live (3s)</div>
      </div>
    </div>
    <div class="header-controls">
      <select id="preset-selector" class="btn" onchange="applyPresetRange(this.value)">
        <option value="1h">1H</option>
        <option value="6h">6H</option>
        <option value="24h" selected>24H</option>
        <option value="7d">7D</option>
        <option value="all">All</option>
      </select>
      <button class="btn" onclick="toggleThemeSelector()">🎨</button>
      <button class="btn" onclick="openExportModal()">💾 Export</button>
      <button class="btn" onclick="toggleTableDrawer()">📊 Table</button>
      <button class="btn btn-accent" onclick="refreshData()">🔄</button>
    </div>
  </header>

  <div class="kpi-bar">
    <div class="kpi-card">
      <div class="kpi-label">Distance</div>
      <div class="kpi-val" id="kpi-dist">0.0<span class="kpi-unit">km</span></div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Peak G-Force</div>
      <div class="kpi-val" id="kpi-gforce">1.00<span class="kpi-unit">G</span></div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Avg Motion Z</div>
      <div class="kpi-val" id="kpi-avgz">9.80<span class="kpi-unit">m/s²</span></div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Heading</div>
      <div class="kpi-val" id="kpi-heading">N<span class="kpi-unit" id="kpi-deg">0°</span></div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Samples</div>
      <div class="kpi-val" id="kpi-samples">0<span class="kpi-unit">pts</span></div>
    </div>
  </div>

  <div class="main-grid">
    <div class="charts-pane">
      <div class="card-pane">
        <div class="card-header">
          <div class="card-title">Motion Acceleration (Z-Axis)</div>
          <div class="sub" id="point-resolution-tag">SQLite Downsampled (Max 500)</div>
        </div>
        <div class="canvas-wrap">
          <canvas id="motionChart"></canvas>
        </div>
        <div class="time-slider-wrap">
          <div class="time-labels">
            <span id="start-time-lbl">Start</span>
            <span id="end-time-lbl">Live</span>
          </div>
          <input type="range" id="timeSlider" min="0" max="100" value="100" oninput="onSliderChange(this.value)" />
        </div>
      </div>
    </div>

    <div class="map-pane">
      <div id="map"></div>
    </div>
  </div>

  <div class="drawer collapsed" id="tableDrawer">
    <table>
      <thead>
        <tr><th>Time</th><th>Lat</th><th>Lng</th><th>Accel Z</th><th>Compass</th></tr>
      </thead>
      <tbody id="tableBody">
        <tr><td colspan="5" style="text-align:center">Waiting for live telemetry...</td></tr>
      </tbody>
    </table>
  </div>

  <!-- Export Modal -->
  <div class="modal-overlay" id="exportModal">
    <div class="modal">
      <div class="modal-title">Export Telemetry Dataset</div>
      <div class="modal-options">
        <label class="radio-opt"><input type="radio" name="exportScope" value="filtered" checked /> Filtered View Only</label>
        <label class="radio-opt"><input type="radio" name="exportScope" value="full" /> Full Sovereign Vault History</label>
      </div>
      <div style="display:flex; gap:8px; width:100%;">
        <button class="btn btn-accent" style="flex:1;" onclick="doExport('csv')">CSV</button>
        <button class="btn btn-accent" style="flex:1;" onclick="doExport('geojson')">GeoJSON</button>
        <button class="btn btn-accent" style="flex:1;" onclick="doExport('json')">JSON</button>
      </div>
      <button class="btn" style="width:100%;" onclick="closeExportModal()">Cancel</button>
    </div>
  </div>

<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
<script>
  let rawRecords = [];
  let displayRecords = [];
  let map, pathPolyline, latestMarker;
  const THEMES = ['cyber', 'oled', 'light', 'nordic'];
  let currentThemeIdx = 0;

  function initMap() {
    try {
      if (typeof L !== 'undefined' && document.getElementById('map')) {
        map = L.map('map').setView([20.5937, 78.9629], 5);
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
          maxZoom: 19, attribution: '© OpenStreetMap'
        }).addTo(map);
        pathPolyline = L.polyline([], { color: '#06b6d4', weight: 4 }).addTo(map);
      }
    } catch(e) {
      console.warn('Map initialization deferred/offline:', e);
    }
  }

  async function querySQL(sql) {
    const res = await fetch('/api/query', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sql: sql })
    });
    const json = await res.json();
    if (!json.success) throw new Error(json.error || 'SQL Query failed');
    return json.data || [];
  }

  function calculateDistance(lat1, lon1, lat2, lon2) {
    const R = 6371;
    const dLat = (lat2 - lat1) * Math.PI / 180;
    const dLon = (lon2 - lon1) * Math.PI / 180;
    const a = Math.sin(dLat/2) * Math.sin(dLat/2) +
              Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
              Math.sin(dLon/2) * Math.sin(dLon/2);
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  }

  function getCardinalHeading(deg) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return directions[Math.round(deg / 45) % 8] || 'N';
  }

  async function refreshData() {
    try {
      const preset = document.getElementById('preset-selector').value;
      let minTs = 0;
      const now = Date.now();
      if (preset === '1h') minTs = now - 3600000;
      else if (preset === '6h') minTs = now - 21600000;
      else if (preset === '24h') minTs = now - 86400000;
      else if (preset === '7d') minTs = now - 604800000;

      // Step 1: Query range bounds from SQLite
      const bounds = await querySQL('SELECT MIN(timestamp) as minT, MAX(timestamp) as maxT FROM telemetry WHERE timestamp >= ' + minTs);
      
      let rows = [];
      const minT = bounds.length ? Number(bounds[0].minT) : NaN;
      const maxT = bounds.length ? Number(bounds[0].maxT) : NaN;
      if (Number.isFinite(minT) && Number.isFinite(maxT)) {
        const spanMs = Math.max(1, maxT - minT);
        
        // Calculate bucket size in ms to downsample directly in SQLite to ~500 points
        const bucketMs = Math.max(1, Math.floor(spanMs / 500));

        if (!Number.isFinite(bucketMs) || bucketMs <= 1000) {
          // High frequency / small window (raw 4s points or safety fallback)
          rows = await querySQL('SELECT id, timestamp, latitude, longitude, accelerometerZ, compassDirection FROM telemetry WHERE timestamp >= ' + minTs + ' ORDER BY timestamp ASC LIMIT 500');
        } else {
          // Large window (24h or 7d) -> SQLite GROUP BY downsampling
          const bkt = Math.round(bucketMs);
          const sql = 'SELECT MIN(id) as id, (CAST(timestamp / ' + bkt + ' AS INT) * ' + bkt + ') as timestamp, AVG(latitude) as latitude, AVG(longitude) as longitude, AVG(accelerometerZ) as accelerometerZ, AVG(compassDirection) as compassDirection FROM telemetry WHERE timestamp >= ' + minTs + ' GROUP BY CAST(timestamp / ' + bkt + ' AS INT) ORDER BY timestamp ASC LIMIT 500';
          rows = await querySQL(sql);
        }
      } else {
        // Fallback for empty or initial query
        rows = await querySQL('SELECT id, timestamp, latitude, longitude, accelerometerZ, compassDirection FROM telemetry ORDER BY timestamp DESC LIMIT 500');
        rows = rows.slice().reverse();
      }

      rawRecords = rows;
      applyAdaptiveDownsample();
      document.getElementById('status-indicator').innerHTML = '<span class="live-dot"></span> Vault Live (3s)';
    } catch (e) {
      document.getElementById('status-indicator').innerHTML = '⚠️ ' + e.message;
    }
  }

  function applyAdaptiveDownsample() {
    if (!rawRecords.length) {
      displayRecords = [];
      updateKPIs();
      renderChart();
      renderTable();
      return;
    }

    const TARGET_BUDGET = 500;
    if (rawRecords.length <= TARGET_BUDGET) {
      displayRecords = rawRecords.slice();
    } else {
      const step = Math.ceil(rawRecords.length / TARGET_BUDGET);
      displayRecords = [];
      for (let i = 0; i < rawRecords.length; i += step) {
        displayRecords.push(rawRecords[i]);
      }
    }

    updateKPIs();
    renderChart();
    updateMap();
    renderTable();
  }

  function updateKPIs() {
    if (!displayRecords.length) {
      document.getElementById('kpi-dist').innerHTML = '0.0<span class="kpi-unit">km</span>';
      document.getElementById('kpi-gforce').innerHTML = '1.00<span class="kpi-unit">G</span>';
      document.getElementById('kpi-avgz').innerHTML = '9.80<span class="kpi-unit">m/s²</span>';
      document.getElementById('kpi-heading').innerHTML = 'N<span class="kpi-unit">0°</span>';
      document.getElementById('kpi-samples').innerHTML = '0<span class="kpi-unit">pts</span>';
      document.getElementById('start-time-lbl').textContent = 'Waiting for data...';
      document.getElementById('end-time-lbl').textContent = 'Live';
      return;
    }
    let totalDist = 0, maxG = 0, sumZ = 0, lastHeading = 0;
    for (let i = 0; i < displayRecords.length; i++) {
      const r = displayRecords[i];
      const z = Math.abs(r.accelerometerZ || 9.8);
      const g = z / 9.8;
      if (g > maxG) maxG = g;
      sumZ += (r.accelerometerZ || 9.8);
      if (i > 0) {
        const prev = displayRecords[i-1];
        if (r.latitude && r.longitude && prev.latitude && prev.longitude) {
          totalDist += calculateDistance(prev.latitude, prev.longitude, r.latitude, r.longitude);
        }
      }
      if (r.compassDirection != null) lastHeading = r.compassDirection;
    }
    document.getElementById('kpi-dist').innerHTML = totalDist.toFixed(1) + '<span class="kpi-unit">km</span>';
    document.getElementById('kpi-gforce').innerHTML = maxG.toFixed(2) + '<span class="kpi-unit">G</span>';
    document.getElementById('kpi-avgz').innerHTML = (sumZ / displayRecords.length).toFixed(2) + '<span class="kpi-unit">m/s²</span>';
    document.getElementById('kpi-heading').innerHTML = getCardinalHeading(lastHeading) + '<span class="kpi-unit">' + Math.round(lastHeading) + '°</span>';
    document.getElementById('kpi-samples').innerHTML = displayRecords.length + '<span class="kpi-unit">pts</span>';
    document.getElementById('start-time-lbl').textContent = new Date(displayRecords[0].timestamp).toLocaleTimeString();
    document.getElementById('end-time-lbl').textContent = new Date(displayRecords[displayRecords.length - 1].timestamp).toLocaleTimeString();
  }

  function renderChart() {
    const canvas = document.getElementById('motionChart');
    if (!canvas) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = canvas.clientWidth * dpr;
    canvas.height = canvas.clientHeight * dpr;
    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    const W = canvas.clientWidth, H = canvas.clientHeight, pad = 24;
    ctx.clearRect(0, 0, W, H);

    // Draw grid baseline
    ctx.strokeStyle = getComputedStyle(document.documentElement).getPropertyValue('--grid-line').trim() || '#334155';
    ctx.lineWidth = 1; ctx.beginPath();
    for (let yRatio = 0.25; yRatio <= 0.75; yRatio += 0.25) {
      const y = pad + (H - 2 * pad) * yRatio;
      ctx.moveTo(pad, y); ctx.lineTo(W - pad, y);
    }
    ctx.stroke();

    if (!displayRecords.length) {
      ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--text-secondary').trim() || '#94a3b8';
      ctx.font = '12px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('Awaiting live telemetry samples (Live 3s polling)...', W / 2, H / 2);
      return;
    }

    const values = displayRecords.map(r => r.accelerometerZ || 9.8);
    const min = Math.min(...values) - 0.5;
    const max = Math.max(...values) + 0.5;
    const range = (max - min) || 1;

    const accentColor = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#06b6d4';
    ctx.strokeStyle = accentColor; ctx.lineWidth = 2.5; ctx.beginPath();
    values.forEach((v, i) => {
      const x = pad + (W - 2 * pad) * (i / Math.max(1, values.length - 1));
      const y = H - pad - (H - 2 * pad) * ((v - min) / range);
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });
    ctx.stroke();
  }

  function updateMap() {
    if (!map) return;
    const coords = displayRecords.filter(r => r.latitude && r.longitude).map(r => [r.latitude, r.longitude]);
    if (!coords.length) return;
    pathPolyline.setLatLngs(coords);
    const last = coords[coords.length - 1];
    if (latestMarker) map.removeLayer(latestMarker);
    latestMarker = L.marker(last).addTo(map).bindPopup('Current Position').openPopup();
    if (coords.length > 1) {
      map.fitBounds(pathPolyline.getBounds(), { padding: [15, 15] });
    } else {
      map.setView(last, 15);
    }
  }

  function renderTable() {
    const tbody = document.getElementById('tableBody');
    if (!tbody) return;
    if (!displayRecords.length) {
      tbody.innerHTML = '<tr><td colspan="5" style="text-align:center">Waiting for live telemetry...</td></tr>';
      return;
    }
    tbody.innerHTML = displayRecords.slice(-50).reverse().map(r => \`
      <tr>
        <td>\${new Date(r.timestamp).toLocaleTimeString()}</td>
        <td>\${r.latitude ? r.latitude.toFixed(4) : '-'}</td>
        <td>\${r.longitude ? r.longitude.toFixed(4) : '-'}</td>
        <td>\${r.accelerometerZ ? r.accelerometerZ.toFixed(2) : '-'}</td>
        <td>\${r.compassDirection ? Math.round(r.compassDirection) + '°' : '-'}</td>
      </tr>
    \`).join('');
  }

  function toggleThemeSelector() {
    currentThemeIdx = (currentThemeIdx + 1) % THEMES.length;
    document.documentElement.setAttribute('data-theme', THEMES[currentThemeIdx]);
    renderChart();
  }

  function toggleTableDrawer() { document.getElementById('tableDrawer').classList.toggle('collapsed'); }
  function openExportModal() { document.getElementById('exportModal').classList.add('active'); }
  function closeExportModal() { document.getElementById('exportModal').classList.remove('active'); }

  function doExport(format) {
    const scope = document.querySelector('input[name="exportScope"]:checked').value;
    const dataset = (scope === 'filtered') ? displayRecords : rawRecords;
    let mime = 'text/plain', ext = format, content = '';
    if (format === 'csv') {
      mime = 'text/csv';
      content = 'id,timestamp,latitude,longitude,accelerometerZ,compassDirection\\n' +
        dataset.map(r => \`"\${r.id}","\${r.timestamp}",\${r.latitude||''},\${r.longitude||''},\${r.accelerometerZ||''},\${r.compassDirection||''}\`).join('\\n');
    } else if (format === 'geojson') {
      mime = 'application/geo+json';
      const features = dataset.filter(r => r.latitude && r.longitude).map(r => ({
        type: 'Feature',
        geometry: { type: 'Point', coordinates: [r.longitude, r.latitude] },
        properties: { timestamp: r.timestamp, accelZ: r.accelerometerZ, compass: r.compassDirection }
      }));
      content = JSON.stringify({ type: 'FeatureCollection', features: features }, null, 2);
    } else {
      mime = 'application/json'; content = JSON.stringify(dataset, null, 2);
    }
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = \`telemeter_\${scope}_\${Date.now()}.\${ext}\`; a.click();
    closeExportModal();
  }

  function onSliderChange(val) {
    if (!rawRecords.length) return;
    const maxIdx = Math.floor((val / 100) * (rawRecords.length - 1));
    displayRecords = rawRecords.slice(0, maxIdx + 1);
    updateKPIs(); renderChart(); updateMap(); renderTable();
  }

  function applyPresetRange(preset) { refreshData(); }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js').catch(() => {}); });
  }

  window.addEventListener('DOMContentLoaded', () => {
    initMap();
    refreshData();
    setInterval(refreshData, 3000); // 3-second realtime live polling
  });
  window.addEventListener('resize', renderChart);
</script>
</body>
</html>`;

  await System.writeVault('telemeter.html', html, 'text/html');
  await System.writeVault('telemetry_dashboard.html', html, 'text/html');
  System.log('Telemeter: HTML written to vault keys telemeter.html & telemetry_dashboard.html');
  return 'Telemeter dashboard updated and live. Open http://localhost:8080/vault/telemeter.html or check Vault Dashboards.';
}
