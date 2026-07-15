import 'dart:convert';
import 'dart:math' as math;

/// Rough token estimate (chars/4) for context gauges — not billing-accurate.
int estimateTokensFromString(String text) {
  if (text.isEmpty) return 0;
  return math.max(1, (utf8.encode(text).length / 4).ceil());
}

int estimateTokensFromParts(Iterable<String> parts) {
  var total = 0;
  for (final p in parts) {
    total += estimateTokensFromString(p);
  }
  return total;
}

/// Default display budget when BYOK model window is unknown.
const int kDefaultContextBudgetTokens = 200000;
