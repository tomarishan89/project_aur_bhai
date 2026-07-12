// Basic smoke test for the Project Aur Bhai Ambient Hub (Command Center default).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:project_aur_bhai/main.dart';
import 'package:project_aur_bhai/presentation/screens/ambient_hub.dart';

void main() {
  testWidgets('Ambient Hub builds with Command Center + nav', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: ProjectAurBhaiApp(),
      ),
    );
    // One frame only: the central indicator runs an infinite breathing animation,
    // so pumpAndSettle would never converge.
    await tester.pump();

    // The hub renders.
    expect(find.byType(AmbientHubScreen), findsOneWidget);

    // Bottom navigation exposes settings / mic / agents entry points.
    expect(find.byIcon(Icons.mic), findsWidgets);
    expect(find.byIcon(Icons.settings), findsWidgets);
    expect(find.byIcon(Icons.extension), findsWidgets);

    // The central tap zone gesture detector is present.
    expect(find.byType(GestureDetector), findsWidgets);
  });
}
