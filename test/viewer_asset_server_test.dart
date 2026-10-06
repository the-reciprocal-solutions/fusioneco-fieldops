import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/bim_viewer/viewer_asset_server.dart';

/// The model viewer's loopback server (docs/bim-viewer.md §4.2): serves the
/// page and registered tiles only, behind a random path token.
void main() {
  late Directory tmp;
  late ViewerAssetServer server;
  final hash = 'a' * 64;
  final other = 'b' * 64;

  Future<(int, List<int>, HttpHeaders)> get(String url, {String method = 'GET'}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      final res = await req.close();
      final body = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return (res.statusCode, body, res.headers);
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('viewer_srv');
    await File('${tmp.path}/$hash.glb').writeAsBytes(utf8.encode('glTF-bytes'));
    server = ViewerAssetServer(
      loadAsset: (path) async => switch (path) {
        'index.html' => utf8.encode('<html>viewer</html>'),
        'viewer.js' => utf8.encode('console.log(1)'),
        _ => null,
      },
      random: Random(7),
    );
    await server.start();
  });

  tearDown(() async {
    await server.close();
    await tmp.delete(recursive: true);
  });

  test('binds to IPv4 loopback with a token path', () {
    expect(server.base, matches(RegExp(r'^http://127\.0\.0\.1:\d+/[0-9a-f]{32}/$')));
    expect(server.appUri.toString(), '${server.base}app/index.html');
    expect(server.tilesBase, '${server.base}tiles/');
  });

  test('serves allow-listed page files with their types', () async {
    final (status, body, headers) = await get(server.appUri.toString());
    expect(status, 200);
    expect(utf8.decode(body), '<html>viewer</html>');
    expect(headers.contentType?.mimeType, 'text/html');
    final (s2, _, h2) = await get('${server.base}app/viewer.js');
    expect(s2, 200);
    expect(h2.contentType?.mimeType, 'text/javascript');
  });

  test('refuses anything off the allow list, even if the loader has it', () async {
    expect((await get('${server.base}app/../../etc/passwd')).$1, 404);
    expect((await get('${server.base}app/secret.js')).$1, 404);
    expect((await get('${server.base}app/vendor/three.module.min.js')).$1, 404, reason: 'allowed, but the fake loader has no bytes');
  });

  test('a tile is served only once registered, by hash — never by path', () async {
    expect((await get('${server.tilesBase}$hash.glb')).$1, 404);
    server.setTiles({hash: '${tmp.path}/$hash.glb', 'not-a-hash': '/etc/hosts'});
    final (status, body, headers) = await get('${server.tilesBase}$hash.glb');
    expect(status, 200);
    expect(utf8.decode(body), 'glTF-bytes');
    expect(headers.contentType?.mimeType, 'model/gltf-binary');
    expect((await get('${server.tilesBase}$other.glb')).$1, 404);
    expect((await get('${server.tilesBase}not-a-hash.glb')).$1, 404);
    // Replacing the set withdraws the old tile.
    server.setTiles({});
    expect((await get('${server.tilesBase}$hash.glb')).$1, 404);
  });

  test('a registered tile whose file is gone is a 404, not a crash', () async {
    server.setTiles({other: '${tmp.path}/missing.glb'});
    expect((await get('${server.tilesBase}$other.glb')).$1, 404);
  });

  test('wrong token or method: 404', () async {
    final wrongToken = server.base.replaceFirst(RegExp(r'/[0-9a-f]{32}/$'), '/${'0' * 32}/');
    expect((await get('${wrongToken}app/index.html')).$1, 404);
    expect((await get(server.appUri.toString(), method: 'POST')).$1, 404);
  });

  test('close stops it; a second start before close is a no-op', () async {
    final base = server.base;
    await server.start();
    expect(server.base, base);
    await server.close();
    expect(server.isRunning, isFalse);
    expect(() => server.base, throwsStateError);
    await expectLater(get('${base}app/index.html'), throwsA(isA<SocketException>()));
  });

  // iOS reclaims a suspended app's listening socket; the engine closes the
  // server on pause and re-binds on resume (2026-10-06). The page's URLs
  // must survive that: same port, same token, tiles still registered.
  test('suspend + start comes back on the same base, tiles still served', () async {
    server.setTiles({hash: '${tmp.path}/$hash.glb'});
    final before = server.base;
    await server.suspend();
    expect(server.isRunning, isFalse);
    await server.start();
    expect(server.base, before);
    final (status, body, _) = await get('${server.tilesBase}$hash.glb');
    expect(status, 200);
    expect(utf8.decode(body), 'glTF-bytes');
  });
}
