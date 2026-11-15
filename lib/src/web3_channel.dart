import 'dart:convert';

import 'web_view_host.dart';

/// How the bridge answers a page and notifies it of changes.
///
/// Every method here ends up evaluating a little JavaScript in the running
/// document. It is an interface rather than a direct [WebViewHost] call so the
/// dispatch can be tested by recording what would have been said, without an
/// engine, a window, or a page.
abstract class Web3Channel {
  /// Resolve a pending `request()` promise.
  Future<void> resolve(int id, Object? result);

  /// Reject a pending `request()` promise with an EIP-1193 code, so a dApp can
  /// branch on 4001 / 4100 / 4200 rather than parsing a message.
  Future<void> reject(int id, int code, String message);

  /// Fire every listener the page registered for [event].
  Future<void> emit(String event, Object? payload);

  /// Write `selectedAddress` on the ALREADY-RUNNING provider object.
  ///
  /// Emitting `accountsChanged` is not enough on its own: a dApp that *reads*
  /// `selectedAddress` instead of subscribing would keep seeing the pre-grant
  /// `null` until a reload. So every grant, disconnect and key-switch does
  /// both. `null` clears it.
  Future<void> setLiveAccount(String? address);
}

/// The real channel: evaluates JavaScript through a [WebViewHost].
///
/// Lives in this package rather than in the apps because it needs nothing
/// engine-specific -- both engines can evaluate script on demand, which is
/// exactly why the response direction was never parameterised.
class HostWeb3Channel implements Web3Channel {
  final WebViewHost host;

  /// Optional tracing. The client surfaces this in its in-app debug panel.
  final void Function(String message)? log;

  const HostWeb3Channel(this.host, {this.log});

  @override
  Future<void> resolve(int id, Object? result) async {
    // `result` is omitted rather than sent as null: the page's resolveRequest
    // branches on `response.error`, and a null result is a legitimate success
    // value for several RPC methods.
    final payload = jsonEncode({'id': id, 'result': ?result});
    await _run(
      'window.FlutterWeb3Bridge.resolveRequest($id, $payload);',
      'resolve #$id',
    );
  }

  @override
  Future<void> reject(int id, int code, String message) async {
    final payload = jsonEncode({
      'id': id,
      'error': {'code': code, 'message': message},
    });
    await _run(
      'window.FlutterWeb3Bridge.resolveRequest($id, $payload);',
      'reject #$id ($code)',
    );
  }

  @override
  Future<void> emit(String event, Object? payload) async {
    final json = jsonEncode(payload);
    // Guarded on every hop: a page that never registered a listener, or one
    // that replaced window.ethereum with its own object, must not throw here.
    final js = '''
      if (window.ethereum && window.ethereum._events && window.ethereum._events['$event']) {
        window.ethereum._events['$event'].forEach(function(handler) {
          try { handler($json); } catch (e) { console.error('[PublicOS] listener threw', e); }
        });
      }
    ''';
    await _run(js, 'emit $event $json');
  }

  @override
  Future<void> setLiveAccount(String? address) async {
    final v = address == null ? 'null' : "'$address'";
    await _run(
      'if (window.ethereum) { window.ethereum.selectedAddress = $v; }',
      'live selectedAddress = ${address ?? "null"}',
    );
  }

  /// Evaluating into a page is best-effort by nature: the document may have
  /// navigated away between the request arriving and the answer being ready.
  /// A throw here must not take down the dispatch, so it is logged and dropped
  /// -- the page's promise dies with the document it belonged to.
  Future<void> _run(String js, String what) async {
    try {
      await host.runJavaScript(js);
      log?.call('[web3] $what');
    } catch (e) {
      log?.call('[web3] failed to $what: $e');
    }
  }
}

/// EIP-1193 event names, spelled once.
///
/// `chainChanged` carries a scalar hex id; `accountsChanged` carries an ARRAY
/// -- `[addr]` when connected, `[]` when disconnected or no longer entitled.
/// Getting that shape wrong is silent: listeners simply misbehave.
abstract final class Web3Events {
  static const chainChanged = 'chainChanged';
  static const accountsChanged = 'accountsChanged';
}
