import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';

import 'chain_registry.dart';
import 'web3_error.dart';

/// Read-only JSON-RPC forwarding.
///
/// A seam rather than a hard-wired HTTP call so the dispatch can be tested
/// without a node, and so an app that already holds a client (or wants to
/// route through its own BSP) can supply one.
abstract class Web3Rpc {
  Future<Object?> call(String method, List<dynamic>? params);
}

/// The methods forwarded verbatim to the node.
///
/// **An allowlist, deliberately, not a fallthrough.** Anything not named here
/// reaches the dispatcher's `default` branch and is refused with 4200. That
/// ordering matters: a method that touches the key or creates a grant must
/// never be reachable by being unlisted, and the way to guarantee that is for
/// silence to mean "no".
///
/// Every entry is read-only. None of them can move value or reveal an account.
const Set<String> readOnlyRpcMethods = {
  'eth_call',
  'eth_getBalance',
  'eth_getCode',
  'eth_getStorageAt',
  'eth_getTransactionCount',
  'eth_getBlockByNumber',
  'eth_getBlockByHash',
  'eth_getTransactionByHash',
  'eth_getTransactionReceipt',
  'eth_getLogs',
  'eth_estimateGas',
  'eth_gasPrice',
  'eth_blockNumber',
  'eth_getBlockTransactionCountByHash',
  'eth_getBlockTransactionCountByNumber',
  'eth_getUncleCountByBlockHash',
  'eth_getUncleCountByBlockNumber',
  'net_listening',
  'net_peerCount',
  'web3_clientVersion',
};

/// Forwards to whatever chain the [ChainRegistry] is currently on.
///
/// A fresh [Web3Client] per call, disposed in a `finally` -- carried over from
/// the client unchanged. It is wasteful for a polling dApp, but a shared
/// long-lived client would have to be invalidated on every chain switch, and
/// leaking one is worse than rebuilding one. Revisit only with a measurement.
class HttpWeb3Rpc implements Web3Rpc {
  final ChainRegistry chains;
  final void Function(String message)? log;

  const HttpWeb3Rpc(this.chains, {this.log});

  @override
  Future<Object?> call(String method, List<dynamic>? params) async {
    final rpcUrl = chains.currentRpcUrl;
    log?.call('[rpc] $method -> $rpcUrl');

    Web3Client? client;
    try {
      client = Web3Client(rpcUrl, http.Client());
      return await client.makeRPCCall<Object?>(method, params ?? const []);
    } catch (e) {
      log?.call('[rpc] $method failed: $e');
      // -32603 is the JSON-RPC internal-error code. The node being unreachable
      // is not the page's fault and not a user rejection, so it must not be
      // reported as either.
      throw Web3Error(-32603, 'RPC call failed: $e');
    } finally {
      client?.dispose();
    }
  }
}
