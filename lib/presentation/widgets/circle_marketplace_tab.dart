import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/services/circle_registry_service.dart';
import 'bhai_code_preview_sheet.dart';

/// Remote Friend Circle listings (multi-city GitHub registry).
class CircleMarketplaceTab extends ConsumerStatefulWidget {
  const CircleMarketplaceTab({super.key});

  @override
  ConsumerState<CircleMarketplaceTab> createState() =>
      _CircleMarketplaceTabState();
}

class _CircleMarketplaceTabState extends ConsumerState<CircleMarketplaceTab> {
  late Future<List<CircleListing>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CircleListing>> _load() {
    return ref.read(circleRegistryProvider).listCircle();
  }

  void _refresh() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CircleListing>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.greenAccent),
          );
        }
        if (snap.hasError) {
          final err = '${snap.error}';
          final notConfigured = err.contains(
            CircleRegistryService.notConfiguredSentinel,
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                notConfigured
                    ? AppConfig.circleNotConfiguredHint
                    : 'Friend Circle error: $err',
                style: TextStyle(
                  color: notConfigured ? Colors.amberAccent : Colors.redAccent,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppConfig.circleFriendApkHint,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              TextButton(onPressed: _refresh, child: const Text('RETRY')),
            ],
          );
        }
        final listings = snap.data ?? const [];
        if (listings.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                AppConfig.circleEmptyHint,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                AppConfig.circleFriendApkHint,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              TextButton(onPressed: _refresh, child: const Text('REFRESH')),
            ],
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: listings.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Friend Circle — open a listing to preview, test, or add to Sandbox.',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                );
              }
              final l = listings[i - 1];
              return Card(
                color: const Color(0xFF1A1A1A),
                child: ListTile(
                  leading: const Icon(
                    Icons.groups_outlined,
                    color: Colors.greenAccent,
                  ),
                  title: Text(
                    l.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    '${l.description}\n${l.license} · ${l.revisionId} · ${l.author}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  isThreeLine: true,
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.white38,
                  ),
                  onTap: () => BhaiCodePreviewSheet.open(
                    context,
                    listing: l.toMarketplaceListing(),
                    showPickup: true,
                    customPickup: (_) => pickupCircleListing(ref, l),
                    onInstalled: _refresh,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
