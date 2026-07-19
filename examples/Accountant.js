/**
 * Reference Accountant Bro Code (MS-AGENT-FEED-AGT1).
 * Consume voice-"tell" cash entries from System.readInbox.
 *
 * Example: "Tell Accountant I spent 500 in cash"
 * Then: "Run Accountant"
 */
async function execute(params) {
  System.log('Accountant reading feed inbox…');
  const items = await System.readInbox({ unreadOnly: true, limit: 50 });
  if (!items || items.length === 0) {
    return 'No new expenses. Tell Accountant that you spent an amount.';
  }

  let total = 0;
  const lines = [];
  const ids = [];
  for (const item of items) {
    ids.push(item.id);
    const m = String(item.text).match(/(\d+(?:\.\d+)?)/);
    const amount = m ? Number(m[1]) : 0;
    total += amount;
    lines.push((item.source || 'voice') + ': ' + item.text);
  }
  await System.consumeInbox({ ids: ids });

  const summary =
    'Recorded ' +
    items.length +
    ' expense entr' +
    (items.length === 1 ? 'y' : 'ies') +
    '; total about ' +
    total +
    '.';
  System.log(summary + ' Details: ' + lines.join(' | '));
  return summary;
}
