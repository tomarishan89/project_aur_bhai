import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_model_catalog.dart';
import 'openrouter_provider.dart';

/// Fetches and caches OpenRouter model ids for Settings dropdowns.
class OpenRouterModelService {
  OpenRouterModelService._();
  static final OpenRouterModelService instance = OpenRouterModelService._();

  List<LlmModelOption>? _cached;
  DateTime? _fetchedAt;
  Future<List<LlmModelOption>>? _inFlight;

  static const _cacheTtl = Duration(hours: 6);

  Future<List<LlmModelOption>> models({String? vendorPrefix}) async {
    final all = await _ensureLoaded();
    if (vendorPrefix == null || vendorPrefix.isEmpty) {
      return [...all, LlmModelCatalog.customOption];
    }
    final filtered = all
        .where((m) => m.id.startsWith(vendorPrefix))
        .toList(growable: false);
    return [...filtered, LlmModelCatalog.customOption];
  }

  Future<List<LlmModelOption>> _ensureLoaded() async {
    final now = DateTime.now();
    if (_cached != null &&
        _fetchedAt != null &&
        now.difference(_fetchedAt!) < _cacheTtl) {
      return _cached!;
    }
    _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<List<LlmModelOption>> _fetch() async {
    try {
      final response = await http
          .get(Uri.parse(OpenRouterProvider.modelsUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return _cached ?? _fallback;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final list = data['data'];
      if (list is! List) return _cached ?? _fallback;
      final options = <LlmModelOption>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        if (id == null || id.isEmpty) continue;
        // Skip odd internal slugs.
        if (id.startsWith('~')) continue;
        final name = raw['name']?.toString();
        options.add(
          LlmModelOption(
            id: id,
            label: (name != null && name.isNotEmpty) ? '$name ($id)' : id,
          ),
        );
      }
      options.sort((a, b) => a.id.compareTo(b.id));
      _cached = options;
      _fetchedAt = DateTime.now();
      return options;
    } catch (_) {
      return _cached ?? _fallback;
    }
  }

  static const _fallback = <LlmModelOption>[
    LlmModelOption(
      id: 'google/gemini-3.5-flash',
      label: 'Gemini 3.5 Flash (google/gemini-3.5-flash)',
    ),
    LlmModelOption(id: 'perplexity/sonar', label: 'Perplexity Sonar'),
    LlmModelOption(id: 'moonshotai/kimi-k2.5', label: 'Kimi K2.5'),
    LlmModelOption(
      id: 'deepseek/deepseek-v4-flash',
      label: 'DeepSeek V4 Flash',
    ),
  ];
}
