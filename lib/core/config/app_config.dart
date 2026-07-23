/// Central strings, flags, and vault keys for MVP closed-circle surface
/// ([MS-APP-CONFIG] / MS-DEV-HYGIENE).
class AppConfig {
  AppConfig._();

  // --- Feature flags ---
  static const bool wakeWordFeatureEnabled = true;
  static const bool circleRegistryFeatureEnabled = true;
  static const bool issueReportsFeatureEnabled = true;

  // --- Wake / privacy (MS-OFFLINE-WAKE) ---
  static const String wakeWordPhraseLabel = 'Aur Bhai';
  /// Interim Porcupine built-in until custom .ppn ships.
  static const String wakeWordInterimBuiltIn = 'Jarvis';
  static const String wakePrivacyTitle = 'Wake listen privacy';
  static const String wakePrivacyBody =
      'While looking for the wake word, Aur Bhai processes mic audio in memory only. '
      'It does not save voice recordings, upload audio, or write wake audio to the vault. '
      'Optional wake-word training samples are a separate, explicit action.';
  static const String wakeListenEnabledLabel = 'Listen for wake word';
  static const String wakeListenSubtitle =
      'Hands-free wake (earphone/mic). No recordings stored while listening.';
  static const String wakeListeningIndicator = 'Listening for wake word…';
  static const String wakeNeedsAccessKey =
      'Add a Picovoice AccessKey in Settings to enable on-device wake detection.';
  static const String wakeCustomPpnHint =
      'For real “Aur Bhai” wake: put Picovoice aur_bhai.ppn in app documents/wake/ '
      'or assets/wake/ (rebuild). Until then listen uses interim Jarvis.';

  // --- Circle registry (MVP-S10) ---
  static const String circlePrefsOwnerKey = 'circle_github_owner';
  static const String circlePrefsRepoKey = 'circle_github_repo';
  static const String circlePrefsTokenKey = 'circle_github_token';
  static const String circlePrefsAuthorKey = 'circle_author_display';
  /// Must match the GitHub repo name exactly (hyphens vs underscores).
  static const String circleDefaultRepo = 'aur_bhai_circle';
  static const String circleIndexPath = 'commons/index.json';
  static const String circleBundleDir = 'commons';
  static const String circlePublishConfirm =
      'Publish source + schema only to your private circle registry. '
      'Telemetry and bound models are not included. Continues over the internet.';
  static const String circleTabLabel = 'FRIEND CIRCLE';
  static const String circleEmptyHint =
      'Friend Circle is configured but has no listings yet. Ask a friend to Publish, then Refresh.';
  static const String circleNotConfiguredHint =
      'Friend Circle not configured. Open Settings → CLOSED CIRCLE, paste GitHub owner, '
      'repo (default aur_bhai_circle — exact name as on GitHub), and a fine-grained '
      'PAT with contents + issues. Then Refresh this tab.';
  static const String circleAuthFailedHint =
      'GitHub rejected the request (401/403). Check PAT scopes (contents + issues) '
      'and that you can access the private repo.';
  static const String circleFriendApkHint =
      'Friends install a signed release APK (not Play Store for closed circle). '
      'Share APK privately; they paste the same owner/repo/token in Settings.';
  /// Future: search on Mere Bhai / Sabke Bhai (deferred).
  static const bool bhaiLogSearchDeferred = true;

  // --- Issue reports (MVP-S12 / S15) ---
  static const String issuePrefsLocalKey = 'issue_reports_v1';
  static const String issueSendConsent =
      'Send a diagnostic fixture (Bhai Code state + errors) to the private circle Issues tracker. '
      'No silent upload — only when you tap Send.';
  static const String issueReporterNoteLabel = 'What is wrong? (optional note)';
  static const String issueReporterNoteHint =
      'Describe what failed so the maintainer can reproduce.';
  static const String issueMyReportsTitle = 'My reports';

  // --- Authoring freeze (S15) ---
  static const String authoringTraceVaultPrefix = 'authoring-trace:';
  static const int authoringTraceMaxTurns = 40;
  static const int authoringTraceMaxCharsPerTurn = 4000;

  // --- Bhai Code Call (S17) ---
  static const bool broCallFeatureEnabled = true;
  static const String broCallCuePhrase = 'Aur Bhai';
  static const String broCallAckPhrase = 'Haan Bhai';
  static const String broCallChannelId = 'aur_bhai_bro_call';
  static const String broCallChannelName = 'Bhai Code calls';

  // --- Headset (S18) ---
  static const String headsetRidingHint =
      'For riding: connect a Bluetooth headset, enable wake listen, keep the wake '
      'notification visible. Say Aur Bhai → wait for Haan Bhai → speak. '
      'OEM battery killers may stop background mic — exempt Aur Bhai if needed.';

  // --- Vault keys ---
  static const String vaultAmbientCandidates = 'model_studio:ambient_candidates';
  static String agentInboxKey(String name) => 'agent:$name:inbox';

  // --- Social seed Bhai Codes (MVP-S13) ---
  static const String socialXterName = 'Xter';
  static const String socialFacebookName = 'FacebookPoster';
}
