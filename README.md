# PublicOS Web3 Bridge

The website-to-wallet bridge shared by the PublicOS apps: the EIP-1193 provider a web page talks to, the dispatch of its requests, the gate that decides which site may see which key, and the signing path (personal messages, EIP-712 typed data, transactions). It owns no widgets and has no opinion about the web engine; each app supplies the webview and a few small interfaces.

Public source under the Business Source License 1.1. Free to use for anything built on the PublicOS network. Each version becomes AGPL-3.0-or-later four years after its release. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

## Use

The package is not on pub.dev. Depend on it from git:

```yaml
dependencies:
  publicos_web3_bridge:
    git:
      url: https://github.com/PublicOS-dev/publicos_web3_bridge.git
```

An app connects it to its own webview and key store through the interfaces in `lib/src/`: `WebViewHost` (the engine), `WalletBinding` (which keys exist and how to sign), `GrantStore` and the consent types in `web3_consent.dart` (what each site was allowed). The PublicOS client and desktop apps are the reference implementations.

## Test

```
flutter test
```

The tests use fakes for the webview, the key store and the network; they need no device and no node.

## Name

The name "PublicOS" is used only by the official apps. If you publish a fork, give it its own name. The rules: https://publicos.dev/library/name-and-phrases/

## Docs

https://publicos.dev/library/
