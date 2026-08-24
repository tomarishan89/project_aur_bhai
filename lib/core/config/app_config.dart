/// Central strings, flags, and vault keys for MVP closed-circle surface
/// ([MS-APP-CONFIG] / MS-DEV-HYGIENE).
class AppConfig {
  AppConfig._();

  // --- Feature flags ---
  static const bool wakeWordFeatureEnabled = true;
  static const bool circleRegistryFeatureEnabled = true;
  static const bool issueReportsFeatureEnabled = true;

  // --- Wake / privacy (MS-OFFLINE-WAKE, free openWakeWord) ---
  static const String wakeWordPhraseLabel = 'Hey Jarvis';

  /// Default free pretrained openWakeWord model label.
  static const String wakeWordInterimBuiltIn = 'Hey Jarvis';
  static const String wakePrivacyTitle = 'Wake listen privacy';
  static const String wakePrivacyBody =
      'While looking for the wake word, Aur Bhai processes mic audio in memory only. '
      'It does not save voice recordings, upload audio, or write wake audio to the vault. '
      'Optional wake-word training samples are a separate, explicit action.';
  static const String wakeListenEnabledLabel = 'Listen for wake word';
  static const String wakeListenSubtitle =
      'Hands-free wake (Bluetooth headset / mic). No recordings stored while listening.';
  static const String wakeListeningIndicator = 'Listening for wake word…';
  static const String wakeNeedsAccessKey =
      'Wake listen needs a free wake model installed (default Hey Jarvis is bundled).';
  static const String wakeCustomPpnHint =
      'Free pretrained models from openWakeWord. Download extras in Settings; '
      'only one model is active at a time. Custom “Aur Bhai” training is later.';
  static const String wakeModelLibraryHint =
      'Android/iOS on-device. Bundled models stay; downloaded models can be deleted '
      'to free space (switch active first).';
  static const String wakeCallBusyMessage =
      'Phone call in progress — wake and mic handshake are paused.';
  static const String defaultMereBhaiPrefsKey = 'default_mere_bhai';

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

  // --- Media controls (Android MediaSession) ---
  static const String mediaControlsToggleLabel = 'Media controls → Aur Bhai';
  static const String mediaControlsToggleSubtitle =
      'Android only. When on, Play/Pause/Next from earbuds, car wheel, or headset '
      'remotes start handshake and do not control music. Off leaves those buttons '
      'with the music app. Earbud ANC long-press (firmware) never reaches apps.';
  static const String headsetRidingHint =
      'Always-on: say the wake word → Haan bhai → speak. On-demand: use the mic '
      'or Android media controls (if the toggle above is on).';

  // --- Vault keys ---
  static const String vaultAmbientCandidates =
      'model_studio:ambient_candidates';
  static String agentInboxKey(String name) => 'agent:$name:inbox';

  // --- Social seed Bhai Codes (MVP-S13) ---
  static const String socialXterName = 'Xter';
  static const String socialFacebookName = 'FacebookPoster';
}
