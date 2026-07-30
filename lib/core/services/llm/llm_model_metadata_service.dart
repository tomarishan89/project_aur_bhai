import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gemini_provider.dart';
import 'llm_capability_catalog.dart';
import 'llm_model_catalog.dart';
import 'openrouter_model_service.dart';
import 'openrouter_provider.dart';

/// Live model metadata for Custom / unknown model ids only.
class LlmModelMetadataService {
  LlmModelMetadataService._();
  static final LlmModelMetadataService instance = LlmModelMetadataService._();

  final Map<String, int> _outputTokenCache = {};

  /// Returns an inferred max output token clamp, or null if unavailable.
  Future<int?> resolveOutputTokenLimit({
    required String providerId,
    required String modelId,
    required String apiKey,
  }) async {
    final m = modelId.trim();
    if (m.isEmpty || m == kLlmModelCustomId) return null;
    if (LlmCapabilityCatalog.isKnownModel(providerId, m)) return null;

    final cacheKey = '$providerId|$m';
    final cached = _outputTokenCache[cacheKey];
    if (cached != null) return cached;

    int? limit;
    if (providerId == GeminiProvider.providerId && apiKey.trim().isNotEmpty) {
      limit = await _geminiOutputLimit(m, apiKey);
    } else if (openRouterBackedProvider(providerId) ||
        providerId == OpenRouterProvider.providerId) {
      limit = await _openRouterOutputLimit(m);
    }

    if (limit != null && limit > 0) {
      _outputTokenCache[cacheKey] = limit;
    }
    return limit;
  }

  Future<int?> _geminiOutputLimit(String modelId, String apiKey) async {
    try {
      final id = modelId.startsWith('models/') ? modelId : 'models/$modelId';
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/$id?key=$apiKey',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map) return null;
      final n = data['outputTokenLimit'] ?? data['output_token_limit'];
      if (n is int) return n;
      if (n is num) return n.toInt();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _openRouterOutputLimit(String modelId) async {
    try {
      // Ensure cache is warm; OpenRouter list does not always include limits.
      await OpenRouterModelService.instance.models();
      // OpenRouter public models payload sometimes has top_provider.max_completion_tokens
      // — fetch raw once if needed.
      final response = await http
          .get(Uri.parse(OpenRouterProvider.modelsUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final list = data['data'];
      if (list is! List) return null;
      for (final raw in list) {
        if (raw is! Map) continue;
        if (raw['id']?.toString() != modelId) continue;
        final top = raw['top_provider'];
        if (top is Map) {
          final n = top['max_completion_tokens'];
          if (n is int) return n;
          if (n is num) return n.toInt();
        }
        final ctx = raw['context_length'];
        if (ctx is int && ctx > 0) return ctx.clamp(256, 128000);
        if (ctx is num) return ctx.toInt().clamp(256, 128000);
        return null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
