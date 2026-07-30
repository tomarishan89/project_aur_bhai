import 'dart:convert';

import 'package:http/http.dart' as http;

/// Short exception text for LLM HTTP failures (no secrets).
String llmHttpError(String label, http.Response response) {
  var detail = '';
  try {
    final body = jsonDecode(response.body);
    if (body is Map) {
      final err = body['error'];
      if (err is Map) {
        final msg = err['message'] ?? err['status'] ?? err['code'];
        if (msg != null) detail = ': $msg';
      } else if (body['message'] != null) {
        detail = ': ${body['message']}';
      }
    }
  } catch (_) {}
  if (detail.length > 160) detail = '${detail.substring(0, 160)}…';
  return '$label status ${response.statusCode}$detail';
}

/// User-facing line for [LlmService] fallbacks.
String llmUserFacingError(Object error) {
  final s = error.toString();
  final lower = s.toLowerCase();
  if (lower.contains('timeout')) {
    return 'AI took too long to respond. Try again, or pick a faster model.';
  }
  if (lower.contains('404') ||
      lower.contains('not_found') ||
      lower.contains('not found')) {
    return 'Model not found. Pick a current model in Settings.';
  }
  if (lower.contains('429') ||
      lower.contains('quota') ||
      lower.contains('rate')) {
    return 'AI quota or rate limit hit. Check billing and try again.';
  }
  if (lower.contains('401') ||
      lower.contains('403') ||
      lower.contains('api key') ||
      lower.contains('invalid')) {
    return 'API key rejected. Check the key in Settings.';
  }
  if (lower.contains('503') || lower.contains('overloaded')) {
    return 'AI service is currently overloaded. Please try again later or switch models.';
  }
  final status = RegExp(r'status (\d+)').firstMatch(s);
  if (status != null) {
    return 'AI error (HTTP ${status.group(1)}). Check connection, key, and model.';
  }
  return 'I had trouble communicating with the AI. Check connection and try again.';
}
