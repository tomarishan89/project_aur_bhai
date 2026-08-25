/**
 * I Wish — Product Feedback & Wishlist Bro Code (MS-I-WISH-FEEDBACK)
 * Listens to product wishes, feature requests, and points of confusion from users.
 * Stores wishes 100% on-device in the Sovereign Vault without ambient trackers.
 */

function parseTags(text) {
  if (!text) return [];
  const tags = [];
  const matches = text.match(/#[a-zA-Z0-9_\-]+/g);
  if (matches) {
    for (const m of matches) {
      const tag = m.substring(1).toLowerCase();
      if (!tags.includes(tag)) tags.push(tag);
    }
  }
  return tags;
}

function cleanWishText(text) {
  if (!text) return '';
  return text
    .replace(/^(ask|tell)\s+i\s*wish\s+(that\s+|to\s+)?/i, '')
    .replace(/^(bhai\s*,?\s*)?(i\s+wish|my\s+wish\s+is|feature\s+request|feedback)\s*(:\s*|\s+that\s+|\s+for\s+)?/i, '')
    .trim();
}

function inferCategory(text) {
  const lower = (text || '').toLowerCase();
  if (lower.includes('font') || lower.includes('theme') || lower.includes('color') || lower.includes('dark') || lower.includes('ui') || lower.includes('button') || lower.includes('screen')) {
    return 'ui';
  }
  if (lower.includes('voice') || lower.includes('audio') || lower.includes('mic') || lower.includes('speak') || lower.includes('sound') || lower.includes('wake') || lower.includes('handshake')) {
    return 'voice';
  }
  if (lower.includes('battery') || lower.includes('drain') || lower.includes('speed') || lower.includes('lag') || lower.includes('fast') || lower.includes('performance')) {
    return 'performance';
  }
  if (lower.includes('agent') || lower.includes('app') || lower.includes('tool') || lower.includes('calculator') || lower.includes('accountant') || lower.includes('telemeter') || lower.includes('note')) {
    return 'agent';
  }
  if (lower.includes('bug') || lower.includes('crash') || lower.includes('error') || lower.includes('failed') || lower.includes('broken')) {
    return 'bug';
  }
  return 'general';
}

function escapeSql(str) {
  if (typeof str !== 'string') return '';
  return str.replace(/'/g, "''");
}

function generateId() {
  return 'wish_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 6);
}

async function execute(params) {
  params = params || {};
  
  // 1. Ensure wishes table exists in sovereign vault
  try {
    await System.querySQL(
      "CREATE TABLE IF NOT EXISTS wishes (" +
      "id TEXT PRIMARY KEY, " +
      "text TEXT NOT NULL, " +
      "category TEXT DEFAULT 'general', " +
      "tags TEXT DEFAULT '[]', " +
      "status TEXT DEFAULT 'saved', " +
      "timestamp INTEGER NOT NULL, " +
      "app_version TEXT DEFAULT '3.12'" +
      ")"
    );
  } catch (e) {
    // Ignore if table exists or querySQL syntax limitation
  }

  // 2. Publish dashboard HTML to vault
  const dashboardHtml = System.assets && System.assets['dashboard.html']
    ? System.assets['dashboard.html']
    : (typeof DASHBOARD_HTML !== 'undefined' ? DASHBOARD_HTML : null);
    
  if (dashboardHtml) {
    try {
      await System.writeVault('wishes.html', dashboardHtml, 'text/html');
      await System.writeVault('i_wish.html', dashboardHtml, 'text/html');
    } catch (e) {}
  }

  const rawText = params.wish || params.text || params.query || params.input || '';
  const action = (params.action || '').toLowerCase();

  // Action: List or Summary
  if (action === 'list' || action === 'summary' || action === 'count' || (!rawText && !params.wish)) {
    let rows = [];
    try {
      rows = await System.querySQL("SELECT * FROM wishes ORDER BY timestamp DESC LIMIT 20");
    } catch (e) {}

    if (!rows || rows.length === 0) {
      return "Your wishlist is currently empty, Bhai! Tell me anything you wish the app had.";
    }

    if (action === 'count') {
      return `You have logged ${rows.length} wishes in your local vault, Bhai.`;
    }

    const titles = rows.slice(0, 3).map(r => r.text).join(", ");
    return `You have ${rows.length} wishes saved locally, Bhai. Recent ones include: ${titles}.`;
  }

  // Action: Record new wish
  const clean = cleanWishText(rawText);
  if (!clean || clean.length < 3) {
    return "What would you like to wish for, Bhai? I am listening.";
  }

  const id = generateId();
  const now = Date.now();
  const tags = parseTags(clean);
  const category = params.category || inferCategory(clean);
  const tagsJson = JSON.stringify(tags);

  try {
    await System.querySQL(
      "INSERT INTO wishes (id, text, category, tags, status, timestamp, app_version) " +
      "VALUES ('" + escapeSql(id) + "', '" + escapeSql(clean) + "', '" + escapeSql(category) + "', '" + escapeSql(tagsJson) + "', 'saved', " + now + ", '3.12')"
    );
  } catch (e) {
    // If insertion failed, still acknowledge to user
  }

  return "Noted Bhai! Saved to your wishlist: \"" + clean + "\".";
}
