import 'web3_error.dart';

/// The chains a webview can talk to, and which one it is currently on.
///
/// One registry per webview: a dApp calling `wallet_switchEthereumChain`
/// changes the chain for ITS page only, never globally.
class ChainRegistry {
  /// Chain id (hex, `0x`-prefixed) to RPC endpoint.
  ///
  /// ⚠️ **This is a FALLBACK for standalone use of the package, not the list
  /// the apps run on.** Both clients pass `chains:` at construction, derived
  /// from their own `lib/data/chain_registry.dart` — the single file that also
  /// feeds the Send sheet, the network pills and the brand marks. Keep this in
  /// step with that file, but the app's copy is the one that ships.
  ///
  /// **Every endpoint here must be measured, not assumed.** Public RPC hosts
  /// rot silently: one starts answering **HTTP 525**, another **401 "API key
  /// disabled"**, a project id starts returning **403**, and a testnet can sit
  /// under what looks like a mainnet entry. A dead entry means a dApp doing the
  /// correct thing (`wallet_switchEthereumChain` to `0x1`) switches
  /// successfully and then reads from a dead host, while the app's own Send
  /// sheet reaches the same chain fine. Every endpoint below answered
  /// `eth_chainId` when measured; re-measure them rather than trusting them.
  static const Map<String, String> defaultChains = {
    '0x1189': 'https://rpc.publicos.dev', // PublicOS 4489
    '0x1': 'https://ethereum-rpc.publicnode.com', // Ethereum Mainnet
    '0xa': 'https://mainnet.optimism.io', // OP Mainnet
    '0x89': 'https://polygon-bor-rpc.publicnode.com', // Polygon PoS
    '0x2105': 'https://mainnet.base.org', // Base
    '0xa4b1': 'https://arb1.arbitrum.io/rpc', // Arbitrum One
    '0x64': 'https://rpc.gnosischain.com', // Gnosis
    '0x38': 'https://bsc-dataseed.binance.org', // BNB Chain
    '0xa86a': 'https://api.avax.network/ext/bc/C/rpc', // Avalanche C-Chain
  };

  /// PublicOS, chain 4489. What a webview starts on.
  ///
  /// ⚠️ **Defaulting to `0x1` (Ethereum mainnet) is a bug with teeth, not a
  /// harmless choice.** A first-party PublicOS app
  /// asks `eth_chainId`, is told **1**, and faithfully writes "Chain ID: 1"
  /// into whatever it builds -- a SIWE sign-in message, say. The server then
  /// verifies that field against the live chain (4489) and rejects the mismatch
  /// as "wrong chain". The signature the user had just approved was doomed
  /// before they tapped it, and nothing on screen said so: the wallet was lying
  /// and the page was honestly repeating it.
  ///
  /// This is the PublicOS browser and its first-party apps live on PublicOS, so
  /// PublicOS is the honest default. External dApps are unaffected -- they call
  /// `wallet_switchEthereumChain` as they would in any wallet.
  static const String publicOsChainId = '0x1189';

  final Map<String, String> _chains;
  String _currentChainId;

  /// Fired when the chain actually changes, so the page can be told.
  /// Not fired when a dApp asks to switch to the chain it is already on.
  final void Function(String chainId)? onChainChanged;

  final void Function(String message)? log;

  ChainRegistry({
    String initialChainId = publicOsChainId,
    Map<String, String>? chains,
    this.onChainChanged,
    this.log,
  })  : _chains = {...(chains ?? defaultChains)},
        _currentChainId = initialChainId;

  String get currentChainId => _currentChainId;

  /// `net_version` -- the same chain, in decimal, as a string.
  String get networkVersion =>
      int.parse(_currentChainId.replaceFirst('0x', ''), radix: 16).toString();

  String? rpcUrlFor(String chainId) => _chains[chainId];

  String get currentRpcUrl {
    final url = _chains[_currentChainId];
    if (url == null) {
      throw Web3Error(4901, 'No RPC endpoint configured for $_currentChainId');
    }
    return url;
  }

  bool supports(String chainId) => _chains.containsKey(chainId);

  /// `wallet_switchEthereumChain`.
  ///
  /// Returns `null` on success, which is what the spec asks for.
  ///
  /// An unknown chain throws **4902 (Unrecognized chain ID)**, not a generic
  /// error. 4902 is the code
  /// dApps actually branch on -- it is their cue to follow up with
  /// `wallet_addEthereumChain`. A generic error just makes them give up, so
  /// this can only turn a dead end into a working path.
  Object? switchChain(String requestedChainId) {
    if (!supports(requestedChainId)) {
      throw Web3Error(
        4902,
        'Unrecognized chain ID $requestedChainId. Try adding it first.',
      );
    }

    if (_currentChainId == requestedChainId) {
      log?.call('[chain] already on $requestedChainId, no event');
      return null;
    }

    _currentChainId = requestedChainId;
    log?.call('[chain] switched to $requestedChainId');
    onChainChanged?.call(requestedChainId);
    return null;
  }

  /// `wallet_addEthereumChain`.
  ///
  /// ⚠️ **DELIBERATELY A NO-OP, and this is a security posture, not laziness.**
  /// Honouring it would let a PAGE register an arbitrary RPC endpoint that we
  /// then send the user's `eth_call`s to -- addresses they query, contracts
  /// they read, timing -- to a host the page chose. Every other wallet gates
  /// this behind an explicit user prompt; we have no such prompt yet.
  ///
  /// So it validates the request and reports success without registering
  /// anything, exactly as the client does today. A dApp that adds and then
  /// switches will get 4902 from [switchChain], which is a clearer failure
  /// than it sounds.
  ///
  /// **TODO: web apps should be able to add chains.** The intended shape is
  /// the same one every other wallet uses -- an explicit
  /// "allow this site to add network X?" consent sheet, after which the chain
  /// is registered here for this webview only. That makes it a [Web3Consent]
  /// question, not a silent registry write, and it is why this method already
  /// validates the request shape: the parsing is the part that survives.
  ///
  /// Until that sheet exists, reporting success while registering nothing is
  /// the least-bad placeholder -- but it IS a placeholder.
  Object? addChain(Map<String, dynamic> chainData) {
    final chainId = chainData['chainId'] as String?;
    final rpcUrls = chainData['rpcUrls'] as List<dynamic>?;

    if (chainId == null) {
      throw const Web3Error(-32602, 'wallet_addEthereumChain: no chainId');
    }
    if (rpcUrls == null || rpcUrls.isEmpty) {
      throw Web3Error(-32602, 'No RPC URLs provided for chain $chainId');
    }

    log?.call('[chain] add $chainId requested (NOT registered - see addChain)');
    return null;
  }
}
