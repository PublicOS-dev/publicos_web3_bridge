import 'dart:convert';

import 'chain_registry.dart';
import 'connect_gate.dart';
import 'eip712.dart';
import 'signing.dart';
import 'transactions.dart';
import 'wallet_binding.dart';
import 'web3_channel.dart';
import 'web3_consent.dart';
import 'web3_error.dart';
import 'web3_rpc.dart';
import 'web_view_host.dart';

/// The EIP-1193 request dispatch: one page message in, one answer out.
///
/// **Read the switch as three bands, because that grouping IS the security
/// model** and it is the reason the ordering is what it is:
///
/// 1. **The door** -- `eth_requestAccounts` and `wallet_requestPermissions`.
///    The only methods that may create a grant.
/// 2. **Passive reads** -- `eth_accounts`, `wallet_getPermissions`, chain info.
///    Never prompt, and return nothing until a grant exists.
/// 3. **Gated key use** -- every signing method. Each calls [ConnectGate
///    .requireGrantFor] BEFORE its handler, on THE ADDRESS THE dApp NAMED, so
///    a signature sheet cannot be summoned by a site that never came through
///    the door, and cannot be answered by a key that site was never given.
///
/// Read-only RPC is forwarded from an **allowlist**; everything unmatched falls
/// to `default` and is refused with 4200. Silence means no.
class Web3Dispatcher {
  final ConnectGate gate;
  final WalletBinding wallet;
  final Web3Consent consent;
  final Web3Channel channel;
  final ChainRegistry chains;
  final Web3Rpc rpc;
  final TransactionExecutor transactions;

  /// The scope this webview is pinned to. A request whose document has left
  /// that scope is refused before it can reach a key.
  final WebScope scope;

  /// The document's current origin, supplied by the host on every navigation.
  /// `null` means unknown, which is treated as out of scope.
  Uri? Function() currentOrigin;

  final void Function(String message)? log;

  Web3Dispatcher({
    required this.gate,
    required this.wallet,
    required this.consent,
    required this.channel,
    required this.chains,
    required this.rpc,
    required this.transactions,
    required this.currentOrigin,
    this.scope = WebScope.unrestricted,
    this.log,
  });

  /// Handle one raw message from the page.
  ///
  /// Never throws: every path answers the page, because an unanswered request
  /// leaves its promise pending forever and the dApp simply hangs. Logging an
  /// error and abandoning the request is exactly that bug.
  Future<void> handle(String messageJson) async {
    int? id;
    try {
      final request = jsonDecode(messageJson) as Map<String, dynamic>;
      id = request['id'] as int?;
      final method = request['method'] as String;
      final params = (request['params'] as List<dynamic>?);

      log?.call('[web3] #$id $method');
      final result = await _dispatch(method, params);
      if (id != null) await channel.resolve(id, result);
    } on Web3Error catch (e) {
      log?.call('[web3] #$id ${e.code}: ${e.message}');
      if (id != null) await channel.reject(id, e.code, e.message);
    } on FormatException catch (e) {
      // Bad params from the page: -32602, the JSON-RPC "invalid params" code.
      if (id != null) await channel.reject(id, -32602, e.message);
    } catch (e) {
      // Anything else still owes the page an answer.
      final msg = e.toString();
      // A rejection thrown as a plain exception (an older sheet, a dismissed
      // route) must still reach the dApp as 4001, because that is the one
      // outcome dApps special-case as "the user said no".
      final code = msg.toLowerCase().contains('reject') ? 4001 : -32603;
      log?.call('[web3] #$id unhandled ($code): $msg');
      if (id != null) await channel.reject(id, code, msg);
    }
  }

  Future<Object?> _dispatch(String method, List<dynamic>? params) async {
    final origin = currentOrigin();

    switch (method) {
      // ── 1. THE DOOR ──────────────────────────────────────────────────────
      // The only methods that may create a grant.
      case 'eth_requestAccounts':
        _requireInScope(origin);
        return gate.requestAccounts(origin);

      case 'wallet_requestPermissions':
        // EIP-2255, and it ALWAYS prompts -- that is the whole point of the
        // method: the standard way a dApp asks the user to re-choose accounts.
        //
        // It does not route into `requestAccounts`, although asking for
        // `eth_accounts` looks like the same act: `requestAccounts` may
        // short-circuit when a grant exists, and inheriting that would close
        // the one standard escape hatch from a wrong selection.
        _requireInScope(origin);
        final accounts = await gate.requestPermissions(origin);
        return [_accountsPermission(accounts)];

      // ── 2. PASSIVE READS ─────────────────────────────────────────────────
      // Never prompt. Empty until granted.
      case 'eth_accounts':
        if (!_inScope(origin)) return const <String>[];
        return gate.grantedAccounts(origin);

      case 'wallet_getPermissions':
        // Reflects the REAL grant instead of always claiming one.
        if (!_inScope(origin)) return const <Map<String, dynamic>>[];
        final granted = await gate.grantedAccounts(origin);
        return granted.isEmpty
            ? const <Map<String, dynamic>>[]
            : [_accountsPermission(granted)];

      case 'eth_chainId':
        return chains.currentChainId;

      case 'net_version':
        return chains.networkVersion;

      // ── 3. GATED KEY USE ─────────────────────────────────────────────────
      // requireGrant runs BEFORE the handler in every one of these.
      case 'personal_sign':
        return _signMessage(origin, params, personalSignParams,
            SignatureKind.message);

      case 'eth_sign':
        return _signMessage(origin, params, ethSignParams,
            SignatureKind.legacyEthSign);

      case 'eth_signTypedData':
      case 'eth_signTypedData_v3':
      case 'eth_signTypedData_v4':
        return _signTyped(origin, params);

      case 'eth_sendTransaction':
        return _transact(origin, params, broadcast: true);

      case 'eth_signTransaction':
        return _transact(origin, params, broadcast: false);

      // ── CHAIN MANAGEMENT ─────────────────────────────────────────────────
      case 'wallet_switchEthereumChain':
        if (params == null || params.isEmpty) {
          throw const FormatException('No chain ID provided');
        }
        final requested =
            (params[0] as Map<String, dynamic>)['chainId'] as String;
        return chains.switchChain(requested);

      case 'wallet_addEthereumChain':
        if (params == null || params.isEmpty) {
          throw const FormatException('No chain data provided');
        }
        return chains.addChain(Map<String, dynamic>.from(params[0] as Map));

      // ── READ-ONLY RPC ────────────────────────────────────────────────────
      default:
        if (readOnlyRpcMethods.contains(method)) {
          return rpc.call(method, params);
        }
        // 4200, a real error -- not a success string. Resolving the STRING
        // 'Method not supported' as a successful result would mean a dApp
        // branching on failure never sees one.
        throw Web3Error.unsupported(method);
    }
  }

  // ── handlers ───────────────────────────────────────────────────────────

  /// **The address the dApp names is the address that signs.**
  ///
  /// Parsing `p.address`, showing it in the consent sheet, and then signing
  /// with the globally selected key is the trap: ask to sign with A while B is
  /// selected and you get a signature from B -- one that does not recover to
  /// A, which is a SIWE login that can never succeed and a retry that does
  /// nothing. The sheet would be telling the truth about the request and lying
  /// about the answer.
  ///
  /// Note the ORDER: params are parsed BEFORE the gate, deliberately. Parsing
  /// second would let an ungranted site hear "not connected" rather than
  /// "malformed params" -- but the gate is per-key, and the key to gate on is
  /// inside those params. A malformed request cannot be authorised against
  /// anything.
  Future<String> _signMessage(
    Uri? origin,
    List<dynamic>? params,
    ({String message, String address}) Function(List<dynamic>?) readParams,
    SignatureKind kind,
  ) async {
    _requireInScope(origin);
    final p = readParams(params);
    await gate.requireGrantFor(origin, p.address);

    final key = await wallet.signingKeyFor(p.address);
    if (key == null) throw const Web3Error(4100, 'No signing key available.');

    final approved = await consent.requestSignature(SignatureRequest(
      origin: origin!,
      kind: kind,
      address: p.address,
      display: p.message,
      payload: p.message,
    ));
    if (!approved) throw const Web3Error.rejected();

    return signPersonalMessage(p.message, key);
  }

  Future<String> _signTyped(Uri? origin, List<dynamic>? params) async {
    _requireInScope(origin);
    final p = signTypedDataParams(params);
    await gate.requireGrantFor(origin, p.address);

    final key = await wallet.signingKeyFor(p.address);
    if (key == null) throw const Web3Error(4100, 'No signing key available.');

    // Parse BEFORE asking. If the payload is malformed or contains a type we
    // cannot encode, the user must never be shown a sheet for it -- approving
    // something we cannot faithfully sign is the worst outcome available.
    final parsed = parseTypedData(p.typedData);

    final approved = await consent.requestSignature(SignatureRequest(
      origin: origin!,
      kind: SignatureKind.typedData,
      address: p.address,
      display: const JsonEncoder.withIndent('  ').convert(parsed),
      payload: parsed,
    ));
    if (!approved) throw const Web3Error.rejected();

    return signTypedData(parsed, key);
  }

  /// `from` is the transaction's version of `p.address`, and it was being
  /// ignored the same way -- worse, it was never read at all: the sheet was
  /// shown the globally selected address while the globally selected key
  /// signed, so a dApp naming a `from` got a transaction sent by someone else.
  ///
  /// Omitted `from` is legal and common, and means "whoever you are": it
  /// resolves to `accounts[0]` -- the same ordering rule `eth_accounts`
  /// answers with, so the two can never disagree.
  Future<String> _transact(
    Uri? origin,
    List<dynamic>? params, {
    required bool broadcast,
  }) async {
    _requireInScope(origin);

    final txData = transactionParams(params);
    final from = await _resolveFrom(origin, txData);
    await gate.requireGrantFor(origin, from);

    final key = await wallet.signingKeyFor(from);
    if (key == null) throw const Web3Error(4100, 'No signing key available.');

    final approved = await consent.requestSignature(SignatureRequest(
      origin: origin!,
      // The two are NOT the same ask: one moves value, the other hands back
      // bytes. The sheet must be able to tell them apart.
      kind: broadcast ? SignatureKind.sendTransaction : SignatureKind.transaction,
      address: from,
      display: _describeTransaction(txData),
      payload: txData,
      to: txData['to'] as String?,
    ));
    if (!approved) throw const Web3Error.rejected();

    return broadcast
        ? transactions.send(txData, key)
        : transactions.signOnly(txData, key);
  }

  /// Whose transaction this is.
  ///
  /// A named `from` is honoured verbatim -- [ConnectGate.requireGrantFor] then
  /// decides whether it is ours and permitted. An absent one falls to
  /// `accounts[0]`, and an absent one with NO grant is 4100 rather than a
  /// silent substitution: there is no honest default identity to sign as.
  Future<String> _resolveFrom(Uri? origin, Map<String, dynamic> txData) async {
    final named = txData['from'];
    if (named is String && named.isNotEmpty) return named;

    final accounts = await gate.grantedAccounts(origin);
    if (accounts.isEmpty) {
      throw const Web3Error(4100, 'Unauthorized: connect this site first.');
    }
    return accounts.first;
  }

  // ── scope ──────────────────────────────────────────────────────────────

  bool _inScope(Uri? origin) => origin != null && scope.allows(origin);

  /// Layer 2 of the scope safeguard: even if the page loaded, it does not get
  /// to use the bridge from outside the scope this view was pinned to.
  ///
  /// This is the layer that catches an SPA moving by `history.pushState`, which
  /// fires no navigation event and so cannot be blocked by the engine.
  void _requireInScope(Uri? origin) {
    if (origin == null) {
      throw const Web3Error(4100, 'This page has no readable origin.');
    }
    if (!scope.allows(origin)) {
      throw Web3Error.outOfScope(origin.toString());
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────

  /// One EIP-2255 `eth_accounts` permission object.
  ///
  /// `restrictReturnedAccounts` carries the WHOLE permitted set, in
  /// `accounts[0]`-first order -- that caveat is exactly the per-site set this
  /// model is built on, and shipping only the first element would under-report
  /// a permission the user actually granted.
  ///
  /// An empty [accounts] is possible (an approved disconnect); the caveat is
  /// then an empty list rather than a crash, so this never reads `.first`.
  Map<String, dynamic> _accountsPermission(List<String> accounts) => {
        'parentCapability': 'eth_accounts',
        'date': DateTime.now().millisecondsSinceEpoch,
        'caveats': [
          {
            'type': 'restrictReturnedAccounts',
            'value': accounts,
          }
        ],
      };

  /// A plain-language summary for the consent sheet, so a caller that does not
  /// want to render the raw object still shows something truthful.
  String _describeTransaction(Map<String, dynamic> tx) {
    final to = tx['to'] as String?;
    final value = tx['value'] as String?;
    final data = tx['data'] as String?;
    final hasData = data != null && data.isNotEmpty && data != '0x';

    final parts = <String>[
      if (to != null && to.isNotEmpty) 'To: $to' else 'Contract deployment',
      if (value != null && value != '0x0' && value != '0x') 'Value: $value',
      if (hasData) 'Data: ${data.length > 20 ? '${data.substring(0, 20)}...' : data}',
    ];
    return parts.join('\n');
  }
}
