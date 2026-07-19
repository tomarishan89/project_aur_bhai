/**
 * S17 demo — queue a local Bro Call (notification + Aur Bhai cue).
 * Say "Haan Bhai" to hear the payload. Needs C2.
 */
async function execute(params) {
  const message = String((params && params.message) ||
    'Your pothole complaint was picked up. Demo only — no network.').trim();
  await System.notifyUser({
    title: 'Update',
    body: message,
    speakText: message
  });
  return 'Call queued. When you hear or see Aur Bhai, say Haan Bhai to hear the message.';
}
