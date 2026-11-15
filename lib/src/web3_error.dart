/// An EIP-1193 provider error, carried back to the page with its numeric
/// `code` so a dApp can branch on it.
///
/// The codes are the standard ones and dApps really do switch on them:
/// * **4001** user rejected the request -- the sheet was dismissed. A dApp
///   shows "you cancelled", not "something went wrong".
/// * **4100** unauthorized -- the origin has no grant. This is what an
///   ungranted page gets for `eth_accounts`, and it is why a page must ask.
/// * **4200** unsupported method.
/// * **4900 / 4901** disconnected / chain not connected.
///
/// Moved out of the client widget unchanged: the wire contract with every dApp
/// on the network depends on these numbers, so they are not ours to tidy.
class Web3Error implements Exception {
  final int code;
  final String message;

  const Web3Error(this.code, this.message);

  /// The user dismissed the sheet. The single most common non-success outcome,
  /// and the one a dApp must be able to tell apart from a failure.
  const Web3Error.rejected([this.message = 'User rejected the request'])
      : code = 4001;

  /// The origin holds no grant for this account.
  const Web3Error.unauthorized([this.message = 'Unauthorized']) : code = 4100;

  const Web3Error.unsupported(String method)
      : code = 4200,
        message = 'Unsupported method: $method';

  /// The request left the scope the webview was pinned to. Not a standard
  /// EIP-1193 code -- reported as unauthorized, because from the page's point
  /// of view that is exactly what it is.
  const Web3Error.outOfScope(String origin)
      : code = 4100,
        message = 'Origin $origin is outside this view\'s allowed scope';

  Map<String, Object?> toJson() => {'code': code, 'message': message};

  @override
  String toString() => 'Web3Error($code): $message';
}
