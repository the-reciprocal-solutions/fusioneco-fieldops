import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Reads one file of the bundled viewer (`assets/bim_viewer/<path>`); null
/// when it isn't there. In the app: `rootBundle.load`; in tests: a map.
typedef ViewerAssetLoader = Future<List<int>?> Function(String path);

/// A tiny HTTP server on 127.0.0.1 that hands the model viewer's WebView
/// its page and the floor's tiles (docs/bim-viewer.md §4.2).
///
/// Why a server and not `loadFile` + a JavaScript channel: the page must
/// fetch 60+ GLB tiles (MBs each) that live as files in the offline tile
/// store. Base64 over a channel costs 33 % and a copy per tile on the UI
/// isolate; Android WebView blocks `fetch()` of `file://` from a `file://`
/// page. A loopback server streams the files straight from disk, and the
/// page is an ordinary `http` origin where ES modules and WASM just work.
///
/// Locked down: bound to IPv4 loopback only (nothing off the phone can
/// reach it), every path starts with a random 128-bit token (another app on
/// the phone can't guess it), GET only, the page files are a fixed allow
/// list, and a tile is served only if its hash was registered by
/// [setTiles] (a hash is never turned into a path). Closed with the screen.
///
/// Cleartext to 127.0.0.1 is already allowed: Android
/// `usesCleartextTraffic="true"`, iOS `NSAllowsArbitraryLoads`.
class ViewerAssetServer {
  ViewerAssetServer({required ViewerAssetLoader loadAsset, Random? random})
      : _loadAsset = loadAsset,
        _token = _mintToken(random ?? Random.secure());

  final ViewerAssetLoader _loadAsset;
  final String _token;
  HttpServer? _server;
  final _assetCache = <String, List<int>>{};
  var _tiles = <String, String>{};

  /// Every file the page may load. Anything else is a 404.
  static const appFiles = <String>{
    'index.html',
    'viewer.js',
    'viewer_math.js',
    'vendor/three.module.min.js',
    'vendor/GLTFLoader.js',
    'vendor/OrbitControls.js',
    'vendor/BufferGeometryUtils.js',
    'vendor/meshopt_decoder.module.js',
  };

  static final _hashFile = RegExp(r'^([0-9a-f]{64})\.glb$');

  static String _mintToken(Random r) =>
      List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  bool get isRunning => _server != null;

  /// `http://127.0.0.1:<port>/<token>/`. Throws before [start].
  String get base {
    final s = _server;
    if (s == null) throw StateError('ViewerAssetServer not started');
    return 'http://127.0.0.1:${s.port}/$_token/';
  }

  /// The page to load in the WebView.
  Uri get appUri => Uri.parse('${base}app/index.html');

  /// What viewer.js prefixes to `<hash>.glb` (the `setTiles` command's base).
  String get tilesBase => '${base}tiles/';

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false; // GLBs are meshopt-compressed already
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  /// Replaces the set of tiles the page may fetch: content hash → file.
  void setTiles(Map<String, String> pathsByHash) {
    _tiles = {
      for (final e in pathsByHash.entries)
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(e.key)) e.key: e.value,
    };
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments;
      if (req.method != 'GET' || segs.length < 3 || segs.first != _token) {
        return await _notFound(res);
      }
      if (segs[1] == 'app') {
        final path = segs.sublist(2).join('/');
        if (!appFiles.contains(path)) return await _notFound(res);
        final bytes = _assetCache[path] ?? await _loadAsset(path);
        if (bytes == null) return await _notFound(res);
        _assetCache[path] = bytes;
        res.headers
          ..contentType = _typeOf(path)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        res.contentLength = bytes.length;
        res.add(bytes);
        return await res.close();
      }
      if (segs[1] == 'tiles' && segs.length == 3) {
        final m = _hashFile.firstMatch(segs[2]);
        final file = m == null ? null : _tiles[m.group(1)!];
        if (file == null) return await _notFound(res);
        final f = File(file);
        if (!await f.exists()) return await _notFound(res);
        res.headers
          ..contentType = ContentType('model', 'gltf-binary')
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        res.contentLength = await f.length();
        await res.addStream(f.openRead());
        return await res.close();
      }
      return await _notFound(res);
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  static Future<void> _notFound(HttpResponse res) {
    res.statusCode = HttpStatus.notFound;
    return res.close();
  }

  static ContentType _typeOf(String path) {
    if (path.endsWith('.html')) return ContentType.html;
    if (path.endsWith('.js')) return ContentType('text', 'javascript', charset: 'utf-8');
    return ContentType.binary;
  }
}
