/// Friend Bro share ops helper (City A → City B closed circle).
///
/// Usage (from Flutter project root):
///   dart run tool/friend_share_ops.dart
///   dart run tool/friend_share_ops.dart --apk
///   dart run tool/friend_share_ops.dart --check
///   dart run tool/friend_share_ops.dart --ensure-repo
///
/// Env for --check / --ensure-repo:
///   CIRCLE_OWNER   GitHub user or org
///   CIRCLE_REPO    default aur_bhai_circle
///   CIRCLE_TOKEN   fine-grained PAT (Contents R/W; Issues R/W optional)
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final ensureRepo = args.contains('--ensure-repo');
  final apkOnly = args.contains('--apk');

  if (apkOnly) {
    final apk = _resolveApk();
    if (apk == null) {
      stderr.writeln(
        'No friend APK found. Run: flutter build apk --release\n'
        'Expected: friend_share/aur-bhai-friend-release.apk',
      );
      exit(1);
    }
    stdout.writeln(apk.absolute.path);
    stdout.writeln(
      'Upload this file to Drive/WhatsApp. Friend Install/Update '
      '(same package → no duplicate). Package: com.example.project_aur_bhai',
    );
    return;
  }

  _printChecklist();
  _printApkStatus();

  if (!check && !ensureRepo) {
    stdout.writeln(
      '\nTip: set CIRCLE_OWNER + CIRCLE_TOKEN, then:\n'
      '  dart run tool/friend_share_ops.dart --check\n'
      '  dart run tool/friend_share_ops.dart --ensure-repo\n'
      'APK path only: dart run tool/friend_share_ops.dart --apk\n',
    );
    return;
  }

  final owner = Platform.environment['CIRCLE_OWNER']?.trim() ?? '';
  final repo = Platform.environment['CIRCLE_REPO']?.trim().isNotEmpty == true
      ? Platform.environment['CIRCLE_REPO']!.trim()
      : 'aur_bhai_circle';
  final token = Platform.environment['CIRCLE_TOKEN']?.trim() ?? '';

  if (owner.isEmpty || token.isEmpty) {
    stderr.writeln(
      'Missing CIRCLE_OWNER and/or CIRCLE_TOKEN in the environment.\n'
      'Create a private repo named $repo, then a fine-grained PAT with '
      'Contents (R/W) on that repo. Paste the same values into the app '
      'Settings → CLOSED CIRCLE.',
    );
    exit(2);
  }

  final client = HttpClient();
  try {
    if (ensureRepo) {
      await _ensureRepo(client, owner: owner, repo: repo, token: token);
    }
    await _checkAccess(client, owner: owner, repo: repo, token: token);
  } finally {
    client.close(force: true);
  }
}

void _printChecklist() {
  stdout.writeln('''
=== Friend Bro share — ops checklist ===

1) GitHub (once)
   - Create private repo: <you>/aur_bhai_circle
   - Fine-grained PAT: Contents Read+Write (Issues R/W for SEND REPORT later)
   - Share PAT with friend OR add them as collaborator; keep a revoke SOP

2) Build APK (this machine)
   - flutter build apk --release
   - Prefer: friend_share/aur-bhai-friend-release.apk
     (fallback: build/app/outputs/flutter-apk/app-release.apk)
   - Same package (com.example.project_aur_bhai) + debug-signed release
     → friend Install updates in place (no delete / no duplicate icon)
   - Put that APK on Drive/WhatsApp (not Play for closed circle)
   - Print path: dart run tool/friend_share_ops.dart --apk

3) City A (you)
   - Install APK
   - Settings → CLOSED CIRCLE: owner, repo, PAT, author display name
   - Publish a simple Bro (e.g. Calculator)
   - Confirm CIRCLE tab (or GitHub web) shows the listing

4) City B (friend)
   - Install/update same APK
   - Same Settings owner/repo/PAT
   - CIRCLE → Refresh → Pick up → Bro at C4 → RUN

5) Smoke green
   - Friend saw listing without a chat file of bundle.json
   - Pickup + RUN on a simple local Bro
   - Different networks preferred

Not required for share: custom aur_bhai.ppn, Bro Call, BT headset, Issues.
''');
}

void _printApkStatus() {
  final apk = _resolveApk();
  if (apk == null) {
    stdout.writeln(
      'APK: missing — run flutter build apk --release, then copy to '
      'friend_share/aur-bhai-friend-release.apk',
    );
  } else {
    final mb = (apk.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
    stdout.writeln('APK ready ($mb MB): ${apk.absolute.path}');
  }
}

/// Prefer the friend_share drop; fall back to Flutter build output.
File? _resolveApk() {
  final candidates = [
    File('friend_share/aur-bhai-friend-release.apk'),
    File('build/app/outputs/flutter-apk/app-release.apk'),
  ];
  for (final f in candidates) {
    if (f.existsSync()) return f;
  }
  return null;
}

Future<void> _ensureRepo(
  HttpClient client, {
  required String owner,
  required String repo,
  required String token,
}) async {
  final get = await _github(
    client,
    method: 'GET',
    path: '/repos/$owner/$repo',
    token: token,
  );
  if (get.statusCode == 200) {
    stdout.writeln('Repo exists: $owner/$repo');
    return;
  }
  if (get.statusCode != 404) {
    stderr.writeln(
      'Could not probe repo ($owner/$repo): HTTP ${get.statusCode} ${get.body}',
    );
    exit(1);
  }

  // Create under the authenticated user. For orgs, create the repo in the UI.
  final user = await _github(
    client,
    method: 'GET',
    path: '/user',
    token: token,
  );
  if (user.statusCode != 200) {
    stderr.writeln('Token cannot read /user: HTTP ${user.statusCode}');
    exit(1);
  }
  final login = (jsonDecode(user.body) as Map)['login'] as String? ?? '';
  if (login != owner) {
    stderr.writeln(
      'Repo missing and CIRCLE_OWNER=$owner is not the token user ($login).\n'
      'Create https://github.com/$owner/$repo privately in the browser, then --check.',
    );
    exit(1);
  }

  final created = await _github(
    client,
    method: 'POST',
    path: '/user/repos',
    token: token,
    body: {
      'name': repo,
      'private': true,
      'description': 'Aur Bhai closed-circle Bro Code registry',
      'auto_init': true,
    },
  );
  if (created.statusCode != 201) {
    stderr.writeln(
      'Create repo failed: HTTP ${created.statusCode} ${created.body}\n'
      'Fine-grained tokens often cannot create repos — create $owner/$repo '
      'in the GitHub UI (private), then re-run --check.',
    );
    exit(1);
  }
  stdout.writeln('Created private repo: $owner/$repo');
}

Future<void> _checkAccess(
  HttpClient client, {
  required String owner,
  required String repo,
  required String token,
}) async {
  final res = await _github(
    client,
    method: 'GET',
    path: '/repos/$owner/$repo',
    token: token,
  );
  if (res.statusCode == 401 || res.statusCode == 403) {
    stderr.writeln(
      'GitHub rejected the token (HTTP ${res.statusCode}).\n'
      'Check PAT access to $owner/$repo and Contents permission.',
    );
    exit(1);
  }
  if (res.statusCode == 404) {
    stderr.writeln(
      'Repo not found: $owner/$repo\n'
      'Create it private, then re-run with --ensure-repo or --check.',
    );
    exit(1);
  }
  if (res.statusCode != 200) {
    stderr.writeln('Unexpected: HTTP ${res.statusCode} ${res.body}');
    exit(1);
  }

  final index = await _github(
    client,
    method: 'GET',
    path: '/repos/$owner/$repo/contents/commons/index.json',
    token: token,
  );
  if (index.statusCode == 404) {
    stdout.writeln(
      'OK: $owner/$repo reachable. commons/index.json not created yet — '
      'first Publish from the app will create it.',
    );
  } else if (index.statusCode == 200) {
    stdout.writeln('OK: $owner/$repo reachable; commons/index.json present.');
  } else if (index.statusCode == 401 || index.statusCode == 403) {
    stderr.writeln(
      'Repo exists but Contents read failed (HTTP ${index.statusCode}). '
      'Grant Contents: Read and write on the PAT.',
    );
    exit(1);
  } else {
    stdout.writeln(
      'OK: $owner/$repo reachable (index probe HTTP ${index.statusCode}).',
    );
  }

  stdout.writeln(
    '\nApp Settings → CLOSED CIRCLE:\n'
    '  owner = $owner\n'
    '  repo  = $repo\n'
    '  token = <same CIRCLE_TOKEN>\n'
    'Friend uses the identical values, then CIRCLE → Refresh → Pick up.',
  );
}

class _GhResponse {
  final int statusCode;
  final String body;
  _GhResponse(this.statusCode, this.body);
}

Future<_GhResponse> _github(
  HttpClient client, {
  required String method,
  required String path,
  required String token,
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.https('api.github.com', path);
  final req = await client.openUrl(method, uri);
  req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  req.headers.set('X-GitHub-Api-Version', '2022-11-28');
  req.headers.set(HttpHeaders.userAgentHeader, 'aur-bhai-friend-share-ops');
  if (body != null) {
    final bytes = utf8.encode(jsonEncode(body));
    req.headers.contentType = ContentType.json;
    req.contentLength = bytes.length;
    req.add(bytes);
  }
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  return _GhResponse(res.statusCode, text);
}
