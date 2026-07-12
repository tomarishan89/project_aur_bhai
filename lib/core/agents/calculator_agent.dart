import 'agent_base.dart';

/// A pure-Dart mathematical expression evaluator for standard arithmetic operations.
class SimpleMathParser {
  final String input;
  int _index = 0;

  SimpleMathParser(this.input);

  double evaluate() {
    if (input.trim().isEmpty) return 0.0;
    _index = 0;
    double val = _parseExpression();
    _skipWhitespace();
    if (_index < input.length) {
      throw FormatException("Unexpected character '${input[_index]}' at index $_index");
    }
    return val;
  }

  void _skipWhitespace() {
    while (_index < input.length && (input[_index] == ' ' || input[_index] == '\t' || input[_index] == '\r' || input[_index] == '\n')) {
      _index++;
    }
  }

  double _parseExpression() {
    double left = _parseTerm();
    while (true) {
      _skipWhitespace();
      if (_index >= input.length) break;
      String op = input[_index];
      if (op == '+' || op == '-') {
        _index++;
        double right = _parseTerm();
        if (op == '+') {
          left += right;
        } else {
          left -= right;
        }
      } else {
        break;
      }
    }
    return left;
  }

  double _parseTerm() {
    double left = _parseFactor();
    while (true) {
      _skipWhitespace();
      if (_index >= input.length) break;
      String op = input[_index];
      if (op == '*' || op == '/') {
        _index++;
        double right = _parseFactor();
        if (op == '*') {
          left *= right;
        } else {
          if (right == 0.0) {
            throw UnsupportedError("Division by zero");
          }
          left /= right;
        }
      } else {
        break;
      }
    }
    return left;
  }

  double _parseFactor() {
    _skipWhitespace();
    if (_index >= input.length) {
      throw const FormatException("Unexpected end of expression");
    }

    String current = input[_index];
    
    // Support unary operators
    if (current == '+') {
      _index++;
      return _parseFactor();
    }
    if (current == '-') {
      _index++;
      return -_parseFactor();
    }

    // Support parentheses
    if (current == '(') {
      _index++;
      double val = _parseExpression();
      _skipWhitespace();
      if (_index >= input.length || input[_index] != ')') {
        throw const FormatException("Unbalanced parenthesis: missing ')'");
      }
      _index++; // consume ')'
      return val;
    }

    // Parse numeric value
    int start = _index;
    bool hasDot = false;
    while (_index < input.length) {
      String ch = input[_index];
      if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
        _index++;
      } else if (ch == '.') {
        if (hasDot) {
          throw const FormatException("Multiple decimal points in a single number");
        }
        hasDot = true;
        _index++;
      } else {
        break;
      }
    }

    if (start == _index) {
      throw FormatException("Unexpected character '${input[_index]}' instead of a number");
    }

    return double.parse(input.substring(start, _index));
  }
}

/// Concrete implementation of the Calculator Agent for Project Aur Bhai.
class CalculatorAgent extends AurBhaiAgent {
  @override
  String get name => "Calculator";

  @override
  String get description => "Evaluates standard arithmetic expressions (e.g., 2+2, 12 * 12, (50 - 10) / 2).";

  @override
  Map<String, AgentParameter> get inputSchema => {
    'expression': const AgentParameter(
      type: 'string',
      description: 'The standard mathematical expression to solve. Cleaned of words, e.g. "2+2" or "10*5-3".',
      required: true,
    ),
  };

  @override
  Future<String> execute(Map<String, dynamic> parameters) async {
    final rawExpression = parameters['expression']?.toString() ?? '';
    
    // Sanitize the expression to keep only math characters
    // Clean words like "calculate", "what is", etc.
    String cleanExpression = rawExpression
        .replaceAll(RegExp(r'[a-zA-Z]'), '') // remove any stray alphabetical chars
        .replaceAll('x', '*')               // convert common verbal symbols
        .replaceAll('X', '*')
        .replaceAll('÷', '/')
        .trim();

    if (cleanExpression.isEmpty) {
      return "No valid mathematical expression was provided.";
    }

    try {
      final parser = SimpleMathParser(cleanExpression);
      final double result = parser.evaluate();
      
      // format result: if it's an integer, print without trailing .0
      String finalResult;
      if (result == result.toInt().toDouble()) {
        finalResult = result.toInt().toString();
      } else {
        finalResult = result.toStringAsFixed(4).replaceAll(RegExp(r'\.?0+$'), '');
      }
      return "Calculator agent says, the answer is $finalResult.";
    } catch (e) {
      return "Calculator agent encountered an error: $e";
    }
  }
}
