/// The website-to-wallet bridge shared by the PublicOS clients.
///
/// **What this package is.** One implementation of the EIP-1193 provider, its
/// request dispatch, the connect-grant gate and the signing path -- the code
/// that mediates between a web page and the user's key.
///
/// **It does not depend on Core.** The flow is webview <-> app <-> core: the
/// app resolves keys and grants and passes them down through [WalletBinding]
/// and [GrantStore]. Core has no opinion about where a signature request came
/// from, and nothing here drags it into one.
///
/// **What this package is not.** It owns no widgets and imports no webview
/// plugin. Rendering and consent chrome are the two places the clients
/// genuinely differ, so both are interfaces here and implementations live in
/// the apps.
///
/// Three things differ between the two clients, and only three. Each is an
/// interface here; everything else -- including every line that touches a
/// private key -- exists exactly once, in this package.
///
/// * [WebViewHost] -- the engine. `webview_flutter` on mobile,
///   `zero_webview_windows` (WebView2) on Windows.
/// * [Web3Consent] -- the ask. Bottom sheets on mobile, glass dialogs on
///   desktop.
/// * navigation interception -- the client pushes first-party links into
///   GoRouter; desktop has no router.
/// * [WebStorageProfile] -- the engine's storage partition. Profiles on
///   Android, data stores on WebKit, user-data folders on WebView2.
///
/// Everything else -- and it is the great majority, including every line that
/// touches a private key -- exists exactly once.
library;

export 'src/chain_registry.dart';
export 'src/connect_gate.dart';
export 'src/eip712.dart';
export 'src/provider_script.dart';
export 'src/web_view_host.dart';
export 'src/web_storage_profile.dart';
export 'src/signing.dart';
export 'src/transactions.dart';
export 'src/web3_channel.dart';
export 'src/web3_dispatcher.dart';
export 'src/web3_consent.dart';
export 'src/web3_rpc.dart';
export 'src/web3_error.dart';
export 'src/wallet_binding.dart';
