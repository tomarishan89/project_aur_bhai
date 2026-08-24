/**
 * Note Taker — Sovereign Note & Idea Vault Bro Code (MS-SEED-BHAI-CATALOG-UX1c)
 * Consumes voice notes, bullet points, tags (#work, #ideas, #todo), answers recall questions, and publishes PWA dashboard.
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

function cleanNoteText(text) {
  if (!text) return '';
  return text
    .replace(/^(ask|tell)\s+note\s*taker\s+(that\s+|to\s+)?/i, '')
    .replace(/^(note\s+down|take\s+a\s+note|jot\s+down|remember\s+that|new\s+note)\s*(:\s*|\s+that\s+|\s+to\s+)?/i, '')
    .trim();
}

function extractTitleAndBody(cleanText) {
  if (!cleanText) return { title: 'Untitled Note', body: '' };
  
  // If text has a period or line break in the first 60 chars, split it
  const lines = cleanText.split(/\n+/);
  if (lines.length > 1) {
    return {
      title: lines[0].trim().replace(/^#+\s*/, ''),
      body: lines.slice(1).join('\n').trim()
    };
  }

  // Short single sentence
  if (cleanText.length <= 45) {
    return { title: cleanText, body: cleanText };
  }

  // Find first sentence
  const sentenceMatch = cleanText.match(/^(.+?[.?!])\s+(.+)$/);
  if (sentenceMatch && sentenceMatch[1].length <= 50) {
    return {
      title: sentenceMatch[1].replace(/[.?!]$/, '').trim(),
      body: cleanText
    };
  }

  // Truncate at word boundary for title
  const truncated = cleanText.substring(0, 40).replace(/\s+\S*$/, '');
  return {
    title: truncated + '…',
    body: cleanText
  };
}

async function loadExistingNotes() {
  try {
    const raw = await System.readVault('notes_ledger.json');
    if (raw) {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : (parsed.notes || []);
    }
  } catch (_) {}
  return [];
}

async function saveNotes(notes) {
  await System.writeVault(
    'notes_ledger.json',
    JSON.stringify({ notes: notes, updatedAt: new Date().toISOString() }, null, 2),
    'application/json'
  );

  // Publish dashboard HTML sidecar to vault
  const dashboardHtml = (System.assets && (System.assets['dashboard.html'] || System.assets['note_taker.html'])) ||
    VAULT_ASSETS['dashboard.html'] ||
    VAULT_ASSETS['note_taker.html'] ||
    '';

  if (dashboardHtml && dashboardHtml.length > 20) {
    await System.writeVault('note_taker.html', dashboardHtml, 'text/html');
    await System.writeVault('dashboard.html', dashboardHtml, 'text/html');
  }
}

// ── Main Entrypoint ────────────────────────────────────────────────────────
(async function() {
  const userText = (typeof text !== 'undefined' && text) ? text.toString() : '';
  const userAction = (typeof action !== 'undefined' && action) ? action.toString().toLowerCase() : '';

  let notes = await loadExistingNotes();

  // 1. Action: Dashboard Open
  if (userAction === 'dashboard' || /^(open|show|launch)\s+dashboard/i.test(userText)) {
    const total = notes.length;
    return `Note Taker has ${total} sovereign notes in your vault. Opening dashboard…`;
  }

  // 2. Action: Search / Recall Query
  const searchMatch = userText.match(/^(what\s+did\s+i\s+note|search\s+notes?\s+for|find\s+notes?\s+about|recall)\s+(.+)/i);
  if (searchMatch) {
    const query = searchMatch[2].replace(/[?.,]$/, '').toLowerCase().trim();
    const matches = notes.filter(n => 
      (n.title && n.title.toLowerCase().includes(query)) ||
      (n.body && n.body.toLowerCase().includes(query)) ||
      (n.tags && n.tags.some(t => t.toLowerCase().includes(query)))
    );

    if (matches.length === 0) {
      return `I couldn't find any notes matching "${query}".`;
    }
    const summaries = matches.slice(0, 3).map(m => `• ${m.title}: ${m.body.substring(0, 60)}`);
    return `Found ${matches.length} matching note(s):\n${summaries.join('\n')}`;
  }

  // 3. Process inbox / text
  const inbox = await System.readInbox({ unreadOnly: true, limit: 50 });
  const incomingTexts = [];
  if (inbox) {
    for (const item of inbox) {
      if (item.text) incomingTexts.push(item.text);
    }
  }
  if (userText && !incomingTexts.includes(userText)) {
    incomingTexts.push(userText);
  }

  if (!incomingTexts.length) {
    const count = notes.length;
    return `Note Taker is ready. You have ${count} notes recorded. Say "Note down..." or "Remember that..." to capture a thought.`;
  }

  const newNotes = [];
  for (const raw of incomingTexts) {
    const clean = cleanNoteText(raw);
    if (!clean) continue;

    const { title, body } = extractTitleAndBody(clean);
    const tags = parseTags(raw);

    // Auto-tag #todo if contains action words
    if (/\b(todo|buy|call|meet|finish|submit|send|remind)\b/i.test(clean) && !tags.includes('todo')) {
      tags.push('todo');
    }

    const note = {
      id: 'note-' + Date.now() + '-' + Math.floor(Math.random() * 1000),
      timestamp: new Date().toISOString(),
      title: title,
      body: body,
      tags: tags,
      pinned: false
    };

    newNotes.push(note);
    notes.unshift(note);
  }

  if (newNotes.length > 0) {
    await saveNotes(notes);
    await System.consumeInbox();
    
    if (newNotes.length === 1) {
      const tagStr = newNotes[0].tags.length ? ` [${newNotes[0].tags.map(t => '#' + t).join(' ')}]` : '';
      return `Noted: "${newNotes[0].title}"${tagStr}`;
    } else {
      return `Recorded ${newNotes.length} new notes into your sovereign vault.`;
    }
  }

  return 'No new note content detected.';
})();
