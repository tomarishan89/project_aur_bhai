/**
 * MVP social Bro Code — post a message via Facebook Graph-style HTTP (user BYOK).
 * Requires Verified (C2) and Facebook key in Settings.
 */
async function execute(params) {
  const text = String((params && params.text) || '').trim();
  const pageId = String((params && params.pageId) || 'me').trim();
  if (!text) {
    return 'Provide text (and optional pageId) to post.';
  }
  const url = 'https://graph.facebook.com/v19.0/' + encodeURIComponent(pageId) + '/feed';
  const payload = JSON.stringify({ message: text });
  try {
    const res = await System.sendHTTP(url, payload);
    System.log('FacebookPoster result: ' + JSON.stringify(res));
    return 'Facebook post attempted. Verify on your page.';
  } catch (e) {
    return 'FacebookPoster failed: ' + e + '. Ensure C2 + Facebook key in Settings.';
  }
}
