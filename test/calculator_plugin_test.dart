import 'package:flutter_test/flutter_test.dart';
import 'package:project_aur_bhai/core/agents/calculator_agent.dart';

void main() {
  group('SimpleMathParser Tests', () {
    test('Basic addition and subtraction', () {
      expect(SimpleMathParser('2+2').evaluate(), 4.0);
      expect(SimpleMathParser('10-3').evaluate(), 7.0);
      expect(SimpleMathParser('1.5 + 2.5').evaluate(), 4.0);
    });

    test('Multiplication and division with precedence', () {
      expect(SimpleMathParser('2 + 3 * 4').evaluate(), 14.0);
      expect(SimpleMathParser('10 / 2 - 1').evaluate(), 4.0);
    });

    test('Parentheses handling', () {
      expect(SimpleMathParser('(2 + 3) * 4').evaluate(), 20.0);
      expect(SimpleMathParser('50 / (2 * (3 + 2))').evaluate(), 5.0);
    });

    test('Unary operators', () {
      expect(SimpleMathParser('-5 + 10').evaluate(), 5.0);
      expect(SimpleMathParser('-(2 + 2)').evaluate(), -4.0);
    });

    test('Exception on division by zero', () {
      expect(
        () => SimpleMathParser('10 / 0').evaluate(),
        throwsUnsupportedError,
      );
    });

    test('Exception on invalid format', () {
      expect(
        () => SimpleMathParser('2 + abc').evaluate(),
        throwsFormatException,
      );
    });
  });

  group('CalculatorAgent Tests', () {
    final agent = CalculatorAgent();

    test('Agent properties', () {
      expect(agent.name, 'Calculator');
      expect(agent.description, isNotEmpty);
      expect(agent.inputSchema.containsKey('expression'), true);
    });

    test('Agent execution returns spoken result', () async {
      final result = await agent.execute({'expression': '12 * 12'});
      expect(result, contains('144'));

      final resultDecimal = await agent.execute({'expression': '10 / 3'});
      expect(resultDecimal, contains('3.3333'));
    });
  });
}
