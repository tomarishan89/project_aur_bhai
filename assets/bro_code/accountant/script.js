/**
 * Accountant — Sovereign Expenditure Logger & Dashboard Bro Code (MS-SEED-BHAI-CATALOG-UX1b)
 * Consumes multi-item voice/text feeds, updates sovereign SQLite ledger, answers questions, and publishes PWA dashboard.
 */

// Category Auto-Classifier Dictionary
const CATEGORY_MAP = {
  Food: ['biscuit', 'biscuits', 'tea', 'chai', 'coffee', 'lunch', 'dinner', 'breakfast', 'snacks', 'samosa', 'burger', 'pizza', 'food', 'restaurant', 'sweets', 'icecream', 'cake', 'bread', 'butter', 'egg', 'eggs', 'maggi'],
  Groceries: ['groceries', 'grocery', 'vegetables', 'sabzi', 'fruits', 'fruit', 'milk', 'doodh', 'ration', 'oil', 'rice', 'dal', 'atta', 'flour', 'sugar', 'salt', 'spices', 'supermarket', 'mart'],
  Travel: ['fuel', 'petrol', 'diesel', 'taxi', 'cab', 'uber', 'ola', 'auto', 'rickshaw', 'metro', 'bus', 'train', 'ticket', 'flight', 'parking', 'toll', 'fare'],
  Shopping: ['flowers', 'flower', 'clothes', 'shirt', 'pants', 'shoes', 'dress', 'shopping', 'amazon', 'flipkart', 'electronics', 'gift', 'gifts', 'book', 'books', 'watch'],
  Bills: ['recharge', 'mobile', 'electricity', 'power', 'wifi', 'broadband', 'internet', 'water', 'rent', 'bill', 'maintenance', 'subscription', 'ott', 'netflix', 'gas', 'cylinder'],
  Health: ['medicine', 'medicines', 'pharmacy', 'doctor', 'clinic', 'hospital', 'test', 'tablet', 'syrup', 'dentist']
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

  // Pattern A: "70 on Flowers, 20 on biscuit", "500 for petrol and 120 on lunch"
  const patternA = /(?:spent|paid)?\s*(\d+(?:\.\d+)?)\s*(?:rupees|rs|in\s+cash|bucks)?\s*(?:on|for)\s*([a-zA-Z0-9\s]+?)(?=(?:,\s*|\s+and\s+|\s+also\s+|\s+with\s+|\s*\.\s*|\s+\d+(?:\.\d+)?\s*(?:on|for)|\s*$))/gi;
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

  // Pattern B: "bought Flowers for 70, biscuit for 20"
  if (results.length === 0) {
    const patternB = /([a-zA-Z0-9\s]+?)\s*(?:for|worth|costing|of)\s*(\d+(?:\.\d+)?)\s*(?:rupees|rs|bucks)?(?=(?:,\s*|\s+and\s+|\s+also\s+|\s*\.|$))/gi;
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

  // Pattern C: "70 flowers 20 biscuit"
  if (results.length === 0) {
    const patternC = /(\d+(?:\.\d+)?)\s+([a-zA-Z]+)/g;
    while ((match = patternC.exec(clean)) !== null) {
      const amount = Number(match[1]);
      const item = match[2].trim();
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

  // Publish dashboard HTML sidecar to vault
  const dashboardHtml = (System.assets && (System.assets['dashboard.html'] || System.assets['accountant.html'])) ||
    VAULT_ASSETS['dashboard.html'] ||
    VAULT_ASSETS['accountant.html'];
  if (dashboardHtml) {
    await System.writeVault('accountant.html', dashboardHtml, 'text/html');
    await System.writeVault('expenditure_dashboard.html', dashboardHtml, 'text/html');
  }
}

async function handleQuestion(query, ledger) {
  const q = query.toLowerCase();

  if (q.includes('total') || q.includes('how much')) {
    // Category check
    for (const cat of Object.keys(CATEGORY_MAP)) {
      if (q.includes(cat.toLowerCase())) {
        const catItems = ledger.filter(e => e.category === cat);
        const sum = catItems.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
        return `You have spent ₹${sum.toFixed(0)} on ${cat} across ${catItems.length} item(s).`;
      }
    }

    // Specific item check
    const matched = ledger.filter(e => q.includes(e.item.toLowerCase()));
    if (matched.length > 0) {
      const sum = matched.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
      return `You spent ₹${sum.toFixed(0)} on ${matched[0].item} (${matched.length} entry/entries).`;
    }

    // Overall total
    const total = ledger.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
    return `Your total expenditure recorded in the sovereign ledger is ₹${total.toFixed(0)} across ${ledger.length} entries.`;
  }

  if (q.includes('highest') || q.includes('biggest') || q.includes('max')) {
    if (!ledger.length) return 'No expenses recorded yet.';
    const highest = ledger.reduce((max, e) => (Number(e.amount) > Number(max.amount) ? e : max), ledger[0]);
    return `Your highest single expense was ₹${highest.amount} on ${highest.item} (${highest.category}).`;
  }

  if (q.includes('recent') || q.includes('last')) {
    if (!ledger.length) return 'No expenses recorded yet.';
    const recent = ledger.slice(0, 3);
    const recStr = recent.map(e => `₹${e.amount} on ${e.item}`).join(', ');
    return `Your recent expenses are: ${recStr}.`;
  }

  const total = ledger.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
  return `You have ${ledger.length} expenses totaling ₹${total.toFixed(0)}. Open the dashboard to view full breakdown.`;
}

async function execute(params) {
  params = params || {};
  System.log('Accountant execution started...');

  const ledger = await loadExistingLedger();

  // 1. Check if user asked to open dashboard
  const userText = String(params.text || params.query || params.message || '').trim();
  if (params.action === 'dashboard' || /open\s+(dashboard|ledger|charts|expenses)/i.test(userText)) {
    await saveLedger(ledger);
    return 'Opening your expenditure dashboard.';
  }

  // 2. Check if user is asking a question about existing expenses
  if (params.query || /^(how much|what (is|was)|tell me|show me|list)\b/i.test(userText)) {
    const question = params.query || userText;
    return await handleQuestion(question, ledger);
  }

  // 3. Process voice feed entries / tell inbox
  const inbox = await System.readInbox({ unreadOnly: true, limit: 50 });
  const textsToProcess = [];
  const idsToConsume = [];

  if (inbox && inbox.length > 0) {
    for (const item of inbox) {
      idsToConsume.push(item.id);
      if (item.text) textsToProcess.push(item.text);
    }
  }

  if (userText && !textsToProcess.includes(userText)) {
    textsToProcess.push(userText);
  }

  if (textsToProcess.length === 0) {
    if (ledger.length > 0) {
      const total = ledger.reduce((acc, e) => acc + (Number(e.amount) || 0), 0);
      return `Accountant is ready. Total recorded is ₹${total.toFixed(0)}. Tell me what you spent (e.g. 70 on Flowers, 20 on biscuit).`;
    }
    return 'No new expenses. Tell Accountant what you spent (e.g., Tell Accountant I spent 70 on Flowers, 20 on biscuit).';
  }

  // 4. Parse items
  const newlyParsed = [];
  for (const txt of textsToProcess) {
    const items = parseExpensesFromText(txt);
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

  if (newlyParsed.length === 0) {
    if (idsToConsume.length > 0) await System.consumeInbox({ ids: idsToConsume });
    return 'I heard: "' + textsToProcess.join(', ') + '", but could not parse the amounts. Please specify amount and item (e.g. 70 on Flowers).';
  }

  // Prepend new items to ledger
  newlyParsed.forEach(e => ledger.unshift(e));
  await saveLedger(ledger);
  if (idsToConsume.length > 0) await System.consumeInbox({ ids: idsToConsume });

  // 5. Build conversational confirmation
  const itemDescriptions = newlyParsed.map(e => `₹${e.amount} on ${e.item}`);
  const sessionTotal = newlyParsed.reduce((sum, e) => sum + e.amount, 0);

  let confirmPhrase = '';
  if (itemDescriptions.length === 1) {
    confirmPhrase = `Logged ${itemDescriptions[0]}.`;
  } else if (itemDescriptions.length === 2) {
    confirmPhrase = `Logged ${itemDescriptions[0]} and ${itemDescriptions[1]}, total ${sessionTotal} rupees.`;
  } else {
    confirmPhrase = `Logged ${itemDescriptions.slice(0, -1).join(', ')}, and ${itemDescriptions[itemDescriptions.length - 1]}, total ${sessionTotal} rupees.`;
  }

  return `${confirmPhrase} Anything else to add, or is that all?`;
}
