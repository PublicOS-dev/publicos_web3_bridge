import 'dart:typed_data';

import 'package:http/http.dart' as http;
// Both of these come from `wallet`, not web3dart, even though web3dart's own
// APIs consume them -- its barrel re-exports almost nothing. Scoped with `show`
// so the rest of wallet's surface does not collide with web3dart's.
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart';

import 'chain_registry.dart';
// Prefixed: web3dart also exports a `hexToBytes`. Ours tolerates odd-length
// input, which a dApp's calldata occasionally is.
import 'eip712.dart' as eip712;
import 'web3_error.dart';

/// Turn a dApp's transaction object into a web3dart [Transaction].
///
/// Everything arrives as `0x` hex strings, and **omitted fields stay null on
/// purpose** -- web3dart then fills nonce, gas and price from the node at send
/// time. Defaulting them here would silently override a node that knows better.
///
/// The EIP-1559 / legacy split is decided by one field: if `maxFeePerGas` is
/// present the transaction is built as 1559, otherwise as legacy `gasPrice`.
/// `maxPriorityFeePerGas` falls back to `maxFeePerGas` when absent, which is
/// what a dApp sending only a cap means.
Transaction buildTransaction(Map<String, dynamic> txData) {
  final to = txData['to'] as String?;
  final toAddress =
      (to != null && to.isNotEmpty) ? EthereumAddress.fromHex(to) : null;

  final maxFee = _weiOrNull(txData['maxFeePerGas']);
  if (maxFee != null) {
    return Transaction(
      to: toAddress,
      value: _wei(txData['value']),
      data: _dataBytes(txData['data']),
      maxGas: _intOrNull(txData['gas']),
      nonce: _intOrNull(txData['nonce']),
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: _weiOrNull(txData['maxPriorityFeePerGas']) ?? maxFee,
    );
  }

  return Transaction(
    to: toAddress,
    value: _wei(txData['value']),
    data: _dataBytes(txData['data']),
    maxGas: _intOrNull(txData['gas']),
    gasPrice: _weiOrNull(txData['gasPrice']),
    nonce: _intOrNull(txData['nonce']),
  );
}

/// Signs and broadcasts, or signs only.
///
/// A seam so the dispatch can be tested without a node -- and because an app
/// that wants to route sends through its own BSP can supply its own.
abstract class TransactionExecutor {
  /// `eth_sendTransaction` -- sign AND broadcast. Returns the tx hash.
  Future<String> send(Map<String, dynamic> txData, EthPrivateKey key);

  /// `eth_signTransaction` -- sign only, hand back the raw signed tx as
  /// `0x`-prefixed hex. Nothing is broadcast.
  Future<String> signOnly(Map<String, dynamic> txData, EthPrivateKey key);
}

/// The default executor: an EOA-direct send on whatever chain the registry is
/// currently on.
///
/// **Send model, carried over deliberately.** The connected web-signing key
/// signs and broadcasts an ordinary transaction, so the sender is the SAME
/// address dApps see through `eth_accounts` / `selectedAddress`. That matches
/// MetaMask semantics and is the right model for a general dApp browser -- a
/// Safe-routed send would arrive from an address the dApp never agreed to.
class ChainTransactionExecutor implements TransactionExecutor {
  final ChainRegistry chains;
  final void Function(String message)? log;

  const ChainTransactionExecutor(this.chains, {this.log});

  @override
  Future<String> send(Map<String, dynamic> txData, EthPrivateKey key) =>
      _withClient((client, chainId) async {
        final hash = await client.sendTransaction(
          key,
          buildTransaction(txData),
          chainId: chainId,
        );
        log?.call('[tx] broadcast $hash');
        return hash;
      });

  @override
  Future<String> signOnly(Map<String, dynamic> txData, EthPrivateKey key) =>
      _withClient((client, chainId) async {
        final signed = await client.signTransaction(
          key,
          buildTransaction(txData),
          chainId: chainId,
        );
        log?.call('[tx] signed, not broadcast (${signed.length} bytes)');
        return '0x${signed.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      });

  Future<String> _withClient(
    Future<String> Function(Web3Client client, int chainId) body,
  ) async {
    final rpcUrl = chains.currentRpcUrl;
    final chainId = int.parse(chains.currentChainId.substring(2), radix: 16);

    // The chain id is signed INTO the transaction (EIP-155), which is what
    // stops a transaction signed for one chain being replayed on another. It
    // must come from the registry, never from the dApp's payload.
    final client = Web3Client(rpcUrl, http.Client());
    try {
      return await body(client, chainId);
    } catch (e) {
      log?.call('[tx] failed: $e');
      throw Web3Error(-32603, 'Transaction failed: $e');
    } finally {
      client.dispose();
    }
  }
}

EtherAmount _wei(dynamic raw) => _weiOrNull(raw) ?? EtherAmount.zero();

EtherAmount? _weiOrNull(dynamic raw) {
  if (raw == null) return null;
  var s = raw.toString();
  if (s.startsWith('0x')) s = s.substring(2);
  if (s.isEmpty) return null;
  return EtherAmount.inWei(BigInt.parse(s, radix: 16));
}

int? _intOrNull(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString();
  if (s.isEmpty) return null;
  return s.startsWith('0x') ? int.parse(s.substring(2), radix: 16) : int.tryParse(s);
}

/// `data` is the calldata. `0x` and empty both mean "no calldata" -- a plain
/// value transfer -- and must become null rather than an empty byte array.
Uint8List? _dataBytes(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString();
  if (s.isEmpty || s == '0x') return null;
  return Uint8List.fromList(eip712.hexToBytes(s));
}

/// `eth_sendTransaction` / `eth_signTransaction` params: `[txObject]`.
Map<String, dynamic> transactionParams(List<dynamic>? params) {
  if (params == null || params.isEmpty) {
    throw const FormatException('Invalid transaction parameters');
  }
  final tx = params[0];
  if (tx is! Map) {
    throw const FormatException('Transaction parameter must be an object');
  }
  return Map<String, dynamic>.from(tx);
}
