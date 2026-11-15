/// How the page hands a request up to Dart.
///
/// The ONLY difference between the two engines inside the injected JavaScript.
/// `webview_flutter` registers a named JavaScript channel and the page calls
/// `<Name>.postMessage(...)`; WebView2 has no such thing and uses its own
/// `window.chrome.webview.postMessage(...)`.
///
/// The reverse direction is deliberately NOT parameterised: responses go back
/// by evaluating `FlutterWeb3Bridge.resolveRequest(...)` in the page on both
/// platforms, because both engines can evaluate script on demand. One response
/// path, one thing to get right.
class BridgeTransport {
  /// A JS expression that posts the local variable `message` up to Dart.
  final String postExpression;

  const BridgeTransport._(this.postExpression);

  /// `webview_flutter` on Android and iOS.
  factory BridgeTransport.javaScriptChannel(String channelName) =>
      BridgeTransport._('$channelName.postMessage(message)');

  /// WebView2, via `zero_webview_windows`.
  static const BridgeTransport webMessage =
      BridgeTransport._('window.chrome.webview.postMessage(message)');
}

/// Builds the EIP-1193 provider installed into every page.
///
/// Copied from `publicos_client`'s webview widget essentially verbatim: this is
/// a wire contract with real dApps -- the MetaMask compatibility flags, the
/// EIP-6963 announcement, the legacy `enable`/`send`/`sendAsync` shims and the
/// `ethereum#initialized` event are all load-bearing for somebody. Do not tidy
/// it because it looks redundant.
///
/// [address] is `null` unless this origin already holds a grant, which is the
/// whole consent posture: **the provider is injected identity-less and a page
/// must ask before it learns who the user is.** Baking the address
/// for an already-granted origin is what lets a returning user skip the sheet
/// and a reading dApp re-hydrate synchronously.
///
/// Re-injection is safe and expected: pending requests survive it, because the
/// map and the id counter are parked on `window`.
String buildProviderScript({
  required String? address,
  required String chainId,
  required BridgeTransport transport,
}) {
  final networkVersion =
      int.parse(chainId.replaceFirst('0x', ''), radix: 16).toString();
  // A JS `null` literal, or a quoted address string. Never an empty string --
  // a dApp checking `if (selectedAddress)` must see a falsy value it expects.
  final selectedAddressJs = address == null ? 'null' : "'$address'";
  final addressLog = address ?? '(none - not connected)';

  return '''
(function() {
  if (window.ethereum) {
    console.log('[PublicOS] Web3 provider already exists, replacing...');
  }

  console.log('[PublicOS] Injecting Web3 Provider');

  // Preserve pending requests across re-injections.
  const pendingRequests = window.__publicOSPendingRequests || new Map();
  window.__publicOSPendingRequests = pendingRequests;

  let requestId = window.__publicOSRequestId || 0;
  window.__publicOSRequestId = requestId;

  // Dart resolves a request by calling into this.
  window.FlutterWeb3Bridge = {
    resolveRequest: function(id, response) {
      console.log('[PublicOS] Resolving request:', id, response);
      const pending = pendingRequests.get(id);
      if (pending) {
        if (response.error) {
          // EIP-1193: reject with a code-bearing error so dApps can branch
          // (4001 user-rejected, 4100 unauthorized, 4200 unsupported).
          const err = new Error(response.error.message);
          if (response.error.code !== undefined) err.code = response.error.code;
          pending.reject(err);
        } else {
          pending.resolve(response.result);
        }
        pendingRequests.delete(id);
      } else {
        console.warn('[PublicOS] No pending request found for ID:', id);
      }
    }
  };

  class PublicOSProvider {
    constructor() {
      this.isPublicOS = true;
      this.isMetaMask = true; // for dApps that gate on it
      this.isConnected = () => true; // EIP-1193: CHAIN connectivity - honestly true
      this.chainId = '$chainId';
      this.selectedAddress = $selectedAddressJs; // null unless this origin is granted
      this.networkVersion = '$networkVersion';
      this._events = {};

      this._metamask = {
        isUnlocked: () => Promise.resolve(true)
      };

      console.log('[PublicOS] Provider initialized with address:', this.selectedAddress);
    }

    async request(args) {
      const { method, params = [] } = args;

      return new Promise((resolve, reject) => {
        requestId = ++window.__publicOSRequestId;
        const id = requestId;

        pendingRequests.set(id, { resolve: resolve, reject: reject });

        const message = JSON.stringify({ id: id, method: method, params: params });

        console.log('[PublicOS] Sending to Flutter:', message);

        try {
          ${transport.postExpression};
        } catch (error) {
          console.error('[PublicOS] Error sending message to Flutter:', error);
          pendingRequests.delete(id);
          reject(error);
        }
      });
    }

    async enable() {
      return this.request({ method: 'eth_requestAccounts' });
    }

    async send(methodOrPayload, paramsOrCallback) {
      if (typeof methodOrPayload === 'string') {
        return this.request({ method: methodOrPayload, params: paramsOrCallback || [] });
      } else {
        return this.sendAsync(methodOrPayload, paramsOrCallback);
      }
    }

    async sendAsync(payload, callback) {
      try {
        const result = await this.request({
          method: payload.method,
          params: payload.params || []
        });
        callback(null, { id: payload.id, jsonrpc: '2.0', result });
      } catch (error) {
        callback(error, null);
      }
    }

    on(event, handler) {
      if (!this._events[event]) {
        this._events[event] = [];
      }
      this._events[event].push(handler);
      console.log('[PublicOS] Event listener added for:', event);
    }

    removeListener(event, handler) {
      if (this._events[event]) {
        this._events[event] = this._events[event].filter(h => h !== handler);
        console.log('[PublicOS] Event listener removed for:', event);
      }
    }

    off(event, handler) {
      this.removeListener(event, handler);
    }
  }

  const publicOSProvider = new PublicOSProvider();

  window.ethereum = publicOSProvider;
  window.web3 = { currentProvider: window.ethereum };

  // Multi-wallet discovery: some dApps read this array instead of window.ethereum.
  if (!window.ethereum.providers) {
    window.ethereum.providers = [publicOSProvider];
  }

  // EIP-6963: announce ourselves to dApps that use the modern discovery flow.
  const announceProvider = () => {
    const info = {
      uuid: 'publicos-wallet-' + Date.now(),
      name: 'PublicOS',
      icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><text y="24" font-size="24">\u{1F310}</text></svg>',
      rdns: 'com.publicos.wallet'
    };

    window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
      detail: Object.freeze({ info, provider: window.ethereum })
    }));

    console.log('[PublicOS] EIP-6963 provider announced');
  };

  window.addEventListener('eip6963:requestProvider', (event) => {
    console.log('[PublicOS] Received EIP-6963 provider request');
    announceProvider();
  });

  announceProvider();

  // Legacy event for older dApps.
  window.dispatchEvent(new Event('ethereum#initialized'));

  console.log('[PublicOS] Web3 Provider injected successfully');
  console.log('[PublicOS] Selected address:', '$addressLog');
  console.log('[PublicOS] Chain ID:', '$chainId');
})();
''';
}
