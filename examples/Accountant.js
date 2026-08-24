/**
 * Reference Accountant Bro Code (MS-SEED-BHAI-CATALOG-UX1b, MS-AGENT-FEED-AGT1).
 * Consumes voice/text feeds, logs to sovereign vault, answers spending queries, and publishes PWA dashboard.
 *
 * Example Invocations:
 * - "Tell Accountant I spent 70 on Flowers, 20 on biscuit"
 * - "Ask Accountant how much did I spend on groceries?"
 * - "Ask Accountant to open dashboard"
 */

const CATEGORY_MAP = {
  Food: ['biscuit', 'biscuits', 'tea', 'coffee', 'lunch', 'dinner', 'snacks', 'burger', 'pizza', 'food', 'sweets'],
  Groceries: ['groceries', 'vegetables', 'fruit', 'milk', 'ration', 'oil', 'rice', 'dal', 'supermarket'],
  Travel: ['fuel', 'petrol', 'diesel', 'taxi', 'cab', 'uber', 'auto', 'metro', 'bus', 'fare', 'parking'],
  Shopping: ['flowers', 'clothes', 'shirt', 'shoes', 'shopping', 'amazon', 'gift', 'books'],
  Bills: ['recharge', 'mobile', 'electricity', 'wifi', 'rent', 'bill', 'subscription'],
  Health: ['medicine', 'pharmacy', 'doctor', 'clinic', 'hospital']
};

function classifyCategory(item) {
  if (!item) return 'General';
  const lower = item.toLowerCase();
  for (const [cat, keywords] of Object.entries(CATEGORY_MAP)) {
    if (keywords.some(k => lower.includes(k))) return cat;
  }
  return 'General';
}

function parseExpensesFromText(text) {
  if (!text) return [];
  const results = [];
  const clean = text.replace(/^(tell|ask)\s+accountant\s+(that\s+|to\s+)?(i\s+)?(spent|paid|bought)?\s*/i, '').trim();

  const patternA = /(?:spent|paid)?\s*(\d+(?:\.\d+)?)\s*(?:rupees|rs|bucks)?\s*(?:on|for)\s*([a-zA-Z0-9\s]+?)(?=(?:,\s*|\s+and\s+|\s+also\s+|\s*\.|$|\s+\d+(?:\.\d+)?\s*(?:on|for)))/gi;
  let match;
  while ((match = patternA.exec(clean)) !== null) {
    const amount = Number(match[1]);
    let item = match[2].trim().replace(/^(and|also|a|an|the)\s+/i, '');
    if (amount > 0 && item.length > 0) {
      results.push({
        item: item.charAt(0).toUpperCase() + item.slice(1),
        amount: amount,
        category: classifyCategory(item)
      });
    }
  }

  if (results.length === 0) {
    const patternB = /([a-zA-Z0-9\s]+?)\s*(?:for|worth|costing|of)\s*(\d+(?:\.\d+)?)\s*(?:rupees|rs|bucks)?(?=(?:,\s*|\s+and\s+|\s*\.|$))/gi;
    while ((match = patternB.exec(clean)) !== null) {
      let item = match[1].trim().replace(/^(bought|paid|spent|got|and|also)\s+/i, '');
      const amount = Number(match[2]);
      if (amount > 0 && item.length > 0) {
        results.push({
          item: item.charAt(0).toUpperCase() + item.slice(1),
          amount: amount,
          category: classifyCategory(item)
        });
      }
    }
  }

  return results;
}

async function loadExistingLedger() {
  try {
    const raw = await System.readVault('accountant_ledger.json');
    if (raw) {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : (parsed.expenses || []);
    }
  } catch (_) {}
  return [];
}

async function saveLedger(expenses) {
  await System.writeVault(
    'accountant_ledger.json',
    JSON.stringify({ expenses: expenses, updatedAt: new Date().toISOString() }, null, 2),
    'application/json'
  );
  const dashboardHtml = (System.assets && (System.assets['dashboard.html'] || System.assets['accountant.html'])) ||
    VAULT_ASSETS['dashboard.html'] ||
    VAULT_ASSETS['accountant.html'];
  if (dashboardHtml) {
    await System.writeVault('accountant.html', dashboardHtml, 'text/html');
  }
}

async function execute(params) {
  params = params || {};
  System.log('Accountant processing request…');
  const ledger = await loadExistingLedger();
  const userText = String(params.text || params.query || params.message || '').trim();

  // 1. Dashboard launch
  if (params.action === 'dashboard' || /open\s+(dashboard|ledger|charts)/i.test(userText)) {
    await saveLedger(ledger);
    return 'Opening your expenditure dashboard.';
  }

  // 2. Spending Q&A
  if (params.query || /^(how much|what (is|was)|tell me|show me)\b/i.test(userText)) {
    const q = (params.query || userText).toLowerCase();
    for (const cat of Object.keys(CATEGORY_MAP)) {
      if (q.includes(cat.toLowerCase())) {
        const catItems = ledger.filter(e => e.category === cat);
        const sum = catItems.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
        return `You have spent ₹${sum.toFixed(0)} on ${cat} across ${catItems.length} item(s).`;
      }
    }
    const total = ledger.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
    return `Total expenses in ledger: ₹${total.toFixed(0)} across ${ledger.length} entries.`;
  }

  // 3. Process inbox / text
  const inbox = await System.readInbox({ unreadOnly: true, limit: 50 });
  const texts = [];
  const ids = [];
  if (inbox) {
    for (const item of inbox) {
      ids.push(item.id);
      if (item.text) texts.push(item.text);
    }
  }
  if (userText && !texts.includes(userText)) texts.push(userText);

  if (!texts.length) {
    const total = ledger.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
    return `Accountant is ready. Total recorded is ₹${total.toFixed(0)}. Tell me what you spent (e.g. 70 on flowers, 20 on biscuit).`;
  }

  const newlyParsed = [];
  for (const t of texts) {
    const items = parseExpensesFromText(t);
    for (const it of items) {
      newlyParsed.push({
        id: 'exp-' + Date.now() + '-' + Math.floor(Math.random() * 1000),
        timestamp: new Date().toISOString(),
        item: it.item,
        amount: it.amount,
        category: it.category,
        note: 'Voice logged'
      });
    }
  }

  if (!newlyParsed.length) {
    if (ids.length) await System.consumeInbox({ ids });
    return 'Could not parse expense amounts. Please specify amount and item (e.g. 70 on Flowers).';
  }

  newlyParsed.forEach(e => ledger.unshift(e));
  await saveLedger(ledger);
  if (ids.length) await System.consumeInbox({ ids });

  const itemDesc = newlyParsed.map(e => `₹${e.amount} on ${e.item}`).join(' and ');
  const sessionTotal = newlyParsed.reduce((sum, e) => sum + e.amount, 0);
  return `Logged ${itemDesc}, total ${sessionTotal} rupees. Anything else to add, or is that all?`;
}
