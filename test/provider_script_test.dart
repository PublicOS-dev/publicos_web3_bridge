import 'package:flutter_test/flutter_test.dart';
import 'package:publicos_web3_bridge/src/provider_script.dart';

void main() {
  String script({String? address, String chain = '0x1189'}) => buildProviderScript(
        address: address,
        chainId: chain,
        transport: BridgeTransport.javaScriptChannel('FlutterWeb3'),
      );

  test('mobile transport posts on the named channel', () {
    expect(script(), contains('FlutterWeb3.postMessage(message)'));
    expect(script(), isNot(contains('chrome.webview')));
  });

  test('windows transport posts on the WebView2 channel', () {
    final s = buildProviderScript(
      address: null,
      chainId: '0x1189',
      transport: BridgeTransport.webMessage,
    );
    expect(s, contains('window.chrome.webview.postMessage(message)'));
    expect(s, isNot(contains('FlutterWeb3.postMessage')));
  });

  test('ungranted origin is injected identity-less', () {
    // The consent posture: a page must ASK before it learns who the user is.
    expect(script(address: null), contains('this.selectedAddress = null;'));
  });

  test('granted origin gets the address baked in, quoted', () {
    expect(
      script(address: '0xabc'),
      contains("this.selectedAddress = '0xabc';"),
    );
  });

  test('networkVersion is the decimal of the hex chainId', () {
    expect(script(chain: '0x1189'), contains("this.networkVersion = '4489';"));
  });

  test('response path is not parameterised - same on both engines', () {
    for (final t in [
      BridgeTransport.javaScriptChannel('FlutterWeb3'),
      BridgeTransport.webMessage,
    ]) {
      final s = buildProviderScript(address: null, chainId: '0x1189', transport: t);
      expect(s, contains('window.FlutterWeb3Bridge'));
      expect(s, contains('resolveRequest'));
    }
  });

  test('dApp compatibility surface survived the move', () {
    final s = script();
    for (final needle in [
      'isMetaMask',
      'eip6963:announceProvider',
      'eip6963:requestProvider',
      "new Event('ethereum#initialized')",
      'async enable()',
      'async sendAsync(',
      'window.ethereum.providers',
      '__publicOSPendingRequests',
    ]) {
      expect(s, contains(needle), reason: 'lost $needle in the move');
    }
  });
}
