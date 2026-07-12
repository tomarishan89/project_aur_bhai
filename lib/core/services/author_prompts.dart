import 'app_spec.dart';

/// Centralized English user-facing author strings (Arch v3.7 — English only).
class AuthorPrompts {
  static String slotQuestion(AppSpecSlot slot) {
    switch (slot) {
      case AppSpecSlot.purpose:
        return 'What should this agent do? Tell me in your own words.';
      case AppSpecSlot.name:
        return 'What should we call it? A short everyday name is fine.';
      case AppSpecSlot.invocationPrompt:
        return 'When you wake the app, what will you say to run this agent?';
      case AppSpecSlot.parameters:
        return 'In that phrase, what details should the agent pick up as variables?';
      case AppSpecSlot.behaviorResponse:
        return 'What should the agent do, and how should it reply when finished?';
      case AppSpecSlot.dataSources:
        return 'Where should it read data from — telemetry, vault, sensors, or something else?';
      case AppSpecSlot.outputs:
        return 'What should it produce — a spoken answer, dashboard, file, or external post?';
      case AppSpecSlot.triggersBeyondVoice:
        return 'Should it run on a schedule or sensor event, or only when you ask?';
      case AppSpecSlot.sensorsPermissions:
        return 'Does it need GPS, accelerometer, or other sensors?';
      case AppSpecSlot.externalKeys:
        return 'Which platform API keys will you need to configure in Settings?';
      case AppSpecSlot.exampleSuccess:
        return 'Give one example: when you say X, it should reply Y.';
      case AppSpecSlot.edgeCases:
        return 'Anything special for offline mode, empty data, or errors?';
      case AppSpecSlot.externalIntegrations:
        return 'Which platform should it post to, and what are the limits — for example a 140-character tweet?';
    }
  }

  static const String sessionCancelled = 'Cancelled. Back to ready.';

  static const String buildFailed =
      'Building the agent failed. Try again or cancel.';

  static const String refineProceedHint = 'Say yes to apply, or cancel.';

  static const String reviewBuildHint =
      'Review it on screen and say build, or tap Build when ready.';

  /// Static capability blurb.
  static const String capabilitiesBlurb =
      'Agents run in a QuickJS sandbox on your phone with a System bridge: '
      'read-only SQL telemetry, write vault dashboards or files, local or authorized '
      'HTTP via System.sendHTTP, and spoken results. Dashboards open from Vault '
      'Dashboards after RUN. Try: build me an agent that…';
}
