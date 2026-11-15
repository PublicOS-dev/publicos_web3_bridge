import 'dart:async';

/// What a page did, reported by the engine.
enum WebViewEventKind { pageStarted, pageFinished, urlChanged, error }

/// One navigation-lifecycle event from the engine.
class WebViewEvent {
  final WebViewEventKind kind;
  final String url;

  /// Only set for [WebViewEventKind.error].
  final String? message;

  /// Only meaningful for errors: a subresource failing is not a dead page.
  final bool isMainFrame;

  const WebViewEvent(
    this.kind,
    this.url, {
    this.message,
    this.isMainFrame = true,
  });
}

/// The engine seam.
///
/// This is the ONLY place the two clients genuinely differ in how web content
/// is rendered: mobile drives `webview_flutter`, Windows drives WebView2
/// through `zero_webview_windows`. Everything above this interface -- the
/// EIP-1193 provider, the request dispatch, the grant gate, the signing path --
/// is one shared implementation and must never learn which engine it is on.
///
/// Implementations are constructed by the app, never by this package: the
/// package must not import a webview plugin.
abstract class WebViewHost {
  /// Navigate the top-level document.
  Future<void> load(Uri url);

  /// Evaluate [js], discarding the result.
  Future<void> runJavaScript(String js);

  /// Evaluate [js] and return its JSON-decoded result.
  Future<Object?> evaluate(String js);

  /// Register [js] to run on EVERY document **before the page's own scripts**.
  ///
  /// This is how the provider should be installed, because a dApp that reads
  /// `window.ethereum` at document-start otherwise wins the race and decides we
  /// do not exist. Proven end to end on WebView2 against real origins
  /// (`flutter.dev`, `app.uniswap.org`).
  ///
  /// **Not universally available** -- see [supportsDocumentStartInjection].
  /// A host that returns `false` must still accept this call and fall back to
  /// injecting on page-finished, which is what the mobile client does today.
  Future<void> injectAtDocumentStart(String js);

  /// Whether [injectAtDocumentStart] genuinely runs before page scripts.
  ///
  /// `true` on WebView2. `false` on `webview_flutter`, which exposes neither
  /// Android's `addDocumentStartJavaScript` nor iOS's `WKUserScript`, so the
  /// mobile client injects on page-finished and loses that race.
  ///
  /// Stated as a capability rather than hidden behind a uniform API on purpose:
  /// this asymmetry is a real security-relevant difference between the two
  /// platforms and the next reader needs to see it.
  bool get supportsDocumentStartInjection;

  /// Navigation lifecycle.
  Stream<WebViewEvent> get events;

  /// Messages posted by the page on the single provider channel.
  ///
  /// Mobile: a `webview_flutter` JavaScript channel. Windows: WebView2's
  /// `postMessage`/`webMessage` pair. Both deliver raw JSON strings; the
  /// difference is absorbed by the host, never by the bridge.
  Stream<String> get messages;

  /// Deliver a JSON string to the page on the same channel.
  Future<void> postMessage(String json);

  Future<void> goBack();
  Future<bool> canGoBack();

  Future<void> dispose();
}

/// Where a webview is allowed to go.
///
/// A record points at one place. Everything under that place is the page; a
/// navigation outside it is a different site and should not silently inherit
/// the wallet bridge. This type is the policy; enforcement has two layers:
///
/// * **the page never loads** -- the engine cancels the navigation. Available
///   on mobile today (`onNavigationRequest`); on Windows it needs a
///   `NavigationStarting` patch in `zero_webview_windows`.
/// * **the provider refuses to serve** -- checked here, at request time,
///   against the document's live location. Needs no engine support, and it is
///   the only layer that catches an SPA moving by `history.pushState`, which
///   fires no navigation event at all.
class WebScope {
  /// Scheme + host + port. A different origin is always out of scope.
  final Uri origin;

  /// Optional tightening: when set, only this path and its descendants are in
  /// scope. Matched on **segment boundaries**, so `/page` admits `/page` and
  /// `/page/a` but never `/pagefoo`.
  final String? pathPrefix;

  const WebScope({required this.origin, this.pathPrefix});

  /// Everything is allowed. The starting posture while the safeguard is being
  /// designed -- deliberately explicit, so that a permissive webview is a
  /// visible choice at the construction site rather than an omission.
  static const WebScope unrestricted = WebScope._unrestricted();
  const WebScope._unrestricted()
      : origin = const _AnyOrigin(),
        pathPrefix = null;

  bool get isUnrestricted => origin is _AnyOrigin;

  /// Derive a scope from the URL a record points at. Origin-only by default;
  /// pass [lockToPath] to also pin the path prefix.
  factory WebScope.of(Uri url, {bool lockToPath = false}) => WebScope(
        origin: Uri(scheme: url.scheme, host: url.host, port: url.hasPort ? url.port : null),
        pathPrefix: lockToPath ? url.path : null,
      );

  bool allows(Uri url) {
    if (isUnrestricted) return true;
    if (url.scheme != origin.scheme || url.host != origin.host) return false;
    final a = url.hasPort ? url.port : _defaultPort(url.scheme);
    final b = origin.hasPort ? origin.port : _defaultPort(origin.scheme);
    if (a != b) return false;
    final p = pathPrefix;
    if (p == null || p.isEmpty || p == '/') return true;
    final want = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final got = url.path;
    // Segment boundary, not string prefix: `/page` must not admit `/pagefoo`.
    return got == want || got.startsWith('$want/');
  }

  static int _defaultPort(String scheme) => scheme == 'http' ? 80 : 443;

  @override
  String toString() => isUnrestricted
      ? 'WebScope(unrestricted)'
      : 'WebScope($origin${pathPrefix ?? ''})';
}

class _AnyOrigin implements Uri {
  const _AnyOrigin();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get scheme => '*';
  @override
  String get host => '*';
  @override
  bool get hasPort => false;
  @override
  String toString() => '*';
}
