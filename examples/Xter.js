/**
 * MVP social Bro Code — post a short status to X (Twitter) via user BYOK key.
 * Requires Verified (C2) and Twitter/X key in Settings.
 */
async function execute(params) {
  const text = String((params && params.text) || '').trim();
  if (!text) {
    return 'Provide text to post (e.g. Run Xter with text="Hello from Aur Bhai").';
  }
  // Platform keys are injected by host for C2 agents; URL is the X API v2 tweets endpoint shape.
  const url = 'https://api.twitter.com/2/tweets';
  const payload = JSON.stringify({ text: text.slice(0, 280) });
  try {
    const res = await System.sendHTTP(url, payload);
    System.log('Xter sendHTTP result: ' + JSON.stringify(res));
    return 'Posted to X (or received API response). Check your X account.';
  } catch (e) {
    return 'Xter failed: ' + e + '. Ensure C2 + Twitter key in Settings.';
  }
}
