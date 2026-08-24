import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/agent_base.dart';
import 'agent_service.dart';
import 'bhai_code_origin.dart';
import 'js_agent_registry.dart';
import 'js_bridge_service.dart';
import 'telemetry_bus.dart';

class McpHandlerService {
  final Ref _ref;

  McpHandlerService(this._ref);

  Future<Map<String, dynamic>> handleJsonRpc(
    Map<String, dynamic> request,
  ) async {
    final method = request['method'] as String?;
    final id = request['id'];

    if (method == 'tools/list') {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [
            {
              'name': 'mcp_list_agents',
              'description':
                  'List all sandbox agents currently installed on the device.',
              'inputSchema': {'type': 'object', 'properties': {}},
            },
            {
              'name': 'mcp_read_agent',
              'description':
                  'Read the source code (JS and HTML assets) for a specific agent.',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'name': {
                    'type': 'string',
                    'description': 'The name of the agent',
                  },
                },
                'required': ['name'],
              },
            },
            {
              'name': 'mcp_deploy_agent',
              'description': 'Deploy or update an agent on the device.',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                  'description': {'type': 'string'},
                  'script': {
                    'type': 'string',
                    'description': 'The JavaScript execution code.',
                  },
                  'vaultAssets': {
                    'type': 'object',
                    'additionalProperties': {'type': 'string'},
                    'description':
                        'A map of filename (e.g. dashboard.html) to string content.',
                  },
                },
                'required': ['name', 'script'],
              },
            },
            {
              'name': 'mcp_run_agent',
              'description':
                  'Execute an installed agent on the device (sovereign mode).',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                },
                'required': ['name'],
              },
            },
            {
              'name': 'mcp_query_telemetry',
              'description':
                  'Query the device telemetry SQLite vault (read-only, guarded).',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'sql': {'type': 'string'},
                },
                'required': ['sql'],
              },
            },
          ],
        },
      };
    } else if (method == 'tools/call') {
      final params = request['params'] as Map<String, dynamic>? ?? {};
      final toolName = params['name'] as String?;
      final toolArgs = params['arguments'] as Map<String, dynamic>? ?? {};

      try {
        final result = await _callTool(toolName, toolArgs);
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': result},
            ],
          },
        };
      } catch (e) {
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': e.toString()},
        };
      }
    }

    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32601, 'message': 'Method not found'},
    };
  }

  Future<String> _callTool(String? name, Map<String, dynamic> args) async {
    final registry = _ref.read(jsAgentRegistryProvider);
    final bridge = _ref.read(jsBridgeServiceProvider);
    final telemetry = _ref.read(telemetryBusProvider);
    final agentService = _ref.read(agentServiceProvider);

    switch (name) {
      case 'mcp_list_agents':
        final names = agentService.all.map((a) => a.name).toList();
        return 'Installed Agents: ${names.join(', ')}';

      case 'mcp_read_agent':
        final agentName = args['name'] as String?;
        if (agentName == null) throw Exception('Missing name');
        final scriptEntry =
            await telemetry.readVaultData(registry.vaultKeyFor(agentName));
        if (scriptEntry == null) return 'Agent not found.';
        final schemaEntry =
            await telemetry.readVaultData(registry.schemaKeyFor(agentName));
        final assets = await registry.readAgentAssets(agentName);
        return jsonEncode({
          'name': agentName,
          'script': scriptEntry['value'],
          'schema':
              schemaEntry != null ? jsonDecode(schemaEntry['value']!) : null,
          'vaultAssets': assets,
        });

      case 'mcp_deploy_agent':
        final agentName = args['name'] as String?;
        final script = args['script'] as String?;
        final description =
            args['description'] as String? ?? 'Deployed via MCP Bridge';
        final vaultAssetsDynamic = args['vaultAssets'] as Map<String, dynamic>?;

        if (agentName == null || script == null) {
          throw Exception('Missing name or script');
        }

        Map<String, String>? vaultAssets;
        if (vaultAssetsDynamic != null) {
          vaultAssets = vaultAssetsDynamic.map(
            (k, v) => MapEntry(k, v.toString()),
          );
        }

        await registry.saveAndRegisterAgent(
          name: agentName,
          description: description,
          inputSchema: <String, AgentParameter>{},
          script: script,
          vaultAssets: vaultAssets,
          source: BhaiCodeOrigin.self,
        );
        return 'Successfully deployed agent "$agentName".';

      case 'mcp_run_agent':
        final agentName = args['name'] as String?;
        if (agentName == null) throw Exception('Missing name');

        final scriptEntry =
            await telemetry.readVaultData(registry.vaultKeyFor(agentName));
        if (scriptEntry == null) return 'Agent not found.';

        final script = scriptEntry['value'] ?? '';
        final assets = await registry.readAgentAssets(agentName);

        final result = await bridge.executeAgentScript(
          agentName: agentName,
          script: script,
          parameters: {},
          sandboxMode: false,
          assets: assets,
        );

        return 'Execution finished.\n'
            'isError: ${result.isError}\n'
            'Message: ${result.message}\n'
            'Vault HTML written: ${result.vaultHtmlKeysWritten.join(', ')}';

      case 'mcp_query_telemetry':
        final sql = args['sql'] as String?;
        if (sql == null) throw Exception('Missing sql');

        final results = await telemetry.executeQuery(sql);
        return jsonEncode(results);

      default:
        throw Exception('Unknown tool: $name');
    }
  }
}

final mcpHandlerServiceProvider = Provider<McpHandlerService>((ref) {
  return McpHandlerService(ref);
});
