import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:get_it/get_it.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:reown_walletkit_wallet/dependencies/chain_services/sui/sui_client.dart';

import 'package:reown_walletkit_wallet/dependencies/i_walletkit_service.dart';
import 'package:reown_walletkit_wallet/dependencies/key_service/i_key_service.dart';
import 'package:reown_walletkit_wallet/models/chain_metadata.dart';
import 'package:reown_walletkit_wallet/utils/methods_utils.dart';

class SUIService {
  late final ReownWalletKit _walletKit;
  late final SuiClient _suiClient;
  final ChainMetadata chainSupported;

  Map<String, dynamic Function(String, dynamic)> get suiRequestHandlers => {
        'sui_signPersonalMessage': suiSignPersonalMessage,
        'sui_signTransaction': suiSignTransaction,
        'sui_signAndExecuteTransaction': suiSignAndExecuteTransaction,
      };

  SUIService({required this.chainSupported}) {
    _walletKit = GetIt.I<IWalletKitService>().walletKit;
    _suiClient = SuiClient(
      projectId: _walletKit.core.projectId,
      networkId: chainSupported.chainId,
    );

    for (var handler in suiRequestHandlers.entries) {
      _walletKit.registerRequestHandler(
        chainId: chainSupported.chainId,
        method: handler.key,
        handler: handler.value,
      );
    }

    _walletKit.onSessionRequest.subscribe(_onSessionRequest);
  }

  Future<void> init() async {
    try {
      await _suiClient.init();
      debugPrint('[$runtimeType] _suiClient initialized');
    } catch (e) {
      debugPrint('❌ [$runtimeType] _suiClient init error, $e');
    }
  }

  Future<String> generateKeyPair({required String networkId}) async {
    return await _suiClient.generateKeyPair(networkId: networkId);
  }

  Future<String> getAddressFromPublicKey({
    required String publicKey,
    required String networkId,
  }) async {
    return await _suiClient.getAddressFromPublicKey(
      publicKey: publicKey,
      networkId: networkId,
    );
  }

  Future<String> getPublicKeyFromKeyPair({
    required String keyPair,
    required String networkId,
  }) async {
    return await _suiClient.getPublicKeyFromKeyPair(
      keyPair: keyPair,
      networkId: networkId,
    );
  }

  Future<void> suiSignPersonalMessage(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] suiSignPersonalMessage: $parameters');
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    try {
      final params = parameters as Map<String, dynamic>;
      final address = params['address'].toString();
      final message = params['message'].toString();

      if (await MethodsUtils.requestApproval(
        message,
        method: pRequest.method,
        chainId: pRequest.chainId,
        address: address,
        transportType: pRequest.transportType.name,
        verifyContext: pRequest.verifyContext,
      )) {
        final signature = await signMessage(message);
        response = response.copyWith(result: {'signature': signature});
      } else {
        final error = Errors.getSdkError(Errors.USER_REJECTED);
        response = response.copyWith(
          error: JsonRpcError(code: error.code, message: error.message),
        );
      }
    } catch (e) {
      debugPrint('[SampleWallet] suiSignPersonalMessage error $e');
      final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
      response = response.copyWith(
        error: JsonRpcError(code: error.code, message: error.message),
      );
    }

    _handleResponseForTopic(topic, response);
  }

  Future<String> signMessage(String message) async {
    final keys = GetIt.I<IKeyService>().getKeysForChain(chainSupported.chainId);
    final suiPrivateKey = keys[0].privateKey;

    final signature = await _suiClient.personalSign(
      keyPair: suiPrivateKey,
      message: message,
      networkId: chainSupported.chainId,
    );
    return signature;
  }

  Future<void> suiSignTransaction(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] suiSignTransaction: ${jsonEncode(parameters)}');
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    final params = parameters as Map<String, dynamic>;
    final address = params['address'] as String;
    final transaction = params['transaction'] as String;
    // {
    //   "transaction": "ewogICJ2ZXJzaW9uIjogMiwKICAic2VuZGVyIjogIjB4ZDVmNjQ3ZWRiNzdkNGZkYTMxZDAzMDQ1MDY0NDdmYjNjOTJlNTVhYWY3N2JjNWVkNGI3N2MzMzJkZDQ2MDVmYSIsCiAgImV4cGlyYXRpb24iOiBudWxsLAogICJnYXNEYXRhIjogewogICAgImJ1ZGdldCI6IG51bGwsCiAgICAicHJpY2UiOiBudWxsLAogICAgIm93bmVyIjogbnVsbCwKICAgICJwYXltZW50IjogbnVsbAogIH0sCiAgImlucHV0cyI6IFsKICAgIHsKICAgICAgIlB1cmUiOiB7CiAgICAgICAgImJ5dGVzIjogIlpBQUFBQUFBQUFBPSIKICAgICAgfQogICAgfSwKICAgIHsKICAgICAgIlB1cmUiOiB7CiAgICAgICAgImJ5dGVzIjogIjFmWkg3YmQ5VDlveDBEQkZCa1IvczhrdVZhcjNlOFh0UzNmRE10MUdCZm89IgogICAgICB9CiAgICB9CiAgXSwKICAiY29tbWFuZHMiOiBbCiAgICB7CiAgICAgICJTcGxpdENvaW5zIjogewogICAgICAgICJjb2luIjogewogICAgICAgICAgIkdhc0NvaW4iOiB0cnVlCiAgICAgICAgfSwKICAgICAgICAiYW1vdW50cyI6IFsKICAgICAgICAgIHsKICAgICAgICAgICAgIklucHV0IjogMAogICAgICAgICAgfQogICAgICAgIF0KICAgICAgfQogICAgfSwKICAgIHsKICAgICAgIlRyYW5zZmVyT2JqZWN0cyI6IHsKICAgICAgICAib2JqZWN0cyI6IFsKICAgICAgICAgIHsKICAgICAgICAgICAgIk5lc3RlZFJlc3VsdCI6IFsKICAgICAgICAgICAgICAwLAogICAgICAgICAgICAgIDAKICAgICAgICAgICAgXQogICAgICAgICAgfQogICAgICAgIF0sCiAgICAgICAgImFkZHJlc3MiOiB7CiAgICAgICAgICAiSW5wdXQiOiAxCiAgICAgICAgfQogICAgICB9CiAgICB9CiAgXQp9",
    //   "address": "0xd5f647edb77d4fda31d0304506447fb3c92e55aaf77bc5ed4b77c332dd4605fa"
    // }

    if (await MethodsUtils.requestApproval(
      transaction,
      method: pRequest.method,
      chainId: pRequest.chainId,
      address: address,
      transportType: pRequest.transportType.name,
      verifyContext: pRequest.verifyContext,
    )) {
      try {
        final keys = GetIt.I<IKeyService>().getKeysForChain(
          chainSupported.chainId,
        );
        final suiPrivateKey = keys[0].privateKey;

        final result = await _suiClient.signTransaction(
          keyPair: suiPrivateKey,
          networkId: chainSupported.chainId,
          txData: transaction,
        );

        response = response.copyWith(
          result: {'signature': result.$1, 'transactionBytes': result.$2},
        );
      } on PlatformException catch (e) {
        debugPrint('[SampleWallet] suiSignTransaction error $e');
        response = response.copyWith(
          error: JsonRpcError(code: -1, message: '${e.code}: ${e.message}'),
        );
      } catch (e) {
        debugPrint('[SampleWallet] suiSignTransaction error $e');
        // print(e);
        final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
        response = response.copyWith(
          error: JsonRpcError(code: error.code, message: error.message),
        );
      }
    } else {
      final error = Errors.getSdkError(Errors.USER_REJECTED);
      response = response.copyWith(
        error: JsonRpcError(code: error.code, message: error.message),
      );
    }

    _handleResponseForTopic(topic, response);
  }

  Future<void> suiSignAndExecuteTransaction(
    String topic,
    dynamic parameters,
  ) async {
    debugPrint(
      '[SampleWallet] suiSignAndExecuteTransaction: ${jsonEncode(parameters)}',
    );
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    final params = parameters as Map<String, dynamic>;
    final address = params['address'] as String;
    final transaction = params['transaction'] as String;
    // {
    //   "transaction": "ewogICJ2ZXJzaW9uIjogMiwKICAic2VuZGVyIjogIjB4ZDVmNjQ3ZWRiNzdkNGZkYTMxZDAzMDQ1MDY0NDdmYjNjOTJlNTVhYWY3N2JjNWVkNGI3N2MzMzJkZDQ2MDVmYSIsCiAgImV4cGlyYXRpb24iOiBudWxsLAogICJnYXNEYXRhIjogewogICAgImJ1ZGdldCI6IG51bGwsCiAgICAicHJpY2UiOiBudWxsLAogICAgIm93bmVyIjogbnVsbCwKICAgICJwYXltZW50IjogbnVsbAogIH0sCiAgImlucHV0cyI6IFsKICAgIHsKICAgICAgIlB1cmUiOiB7CiAgICAgICAgImJ5dGVzIjogIlpBQUFBQUFBQUFBPSIKICAgICAgfQogICAgfSwKICAgIHsKICAgICAgIlB1cmUiOiB7CiAgICAgICAgImJ5dGVzIjogIjFmWkg3YmQ5VDlveDBEQkZCa1IvczhrdVZhcjNlOFh0UzNmRE10MUdCZm89IgogICAgICB9CiAgICB9CiAgXSwKICAiY29tbWFuZHMiOiBbCiAgICB7CiAgICAgICJTcGxpdENvaW5zIjogewogICAgICAgICJjb2luIjogewogICAgICAgICAgIkdhc0NvaW4iOiB0cnVlCiAgICAgICAgfSwKICAgICAgICAiYW1vdW50cyI6IFsKICAgICAgICAgIHsKICAgICAgICAgICAgIklucHV0IjogMAogICAgICAgICAgfQogICAgICAgIF0KICAgICAgfQogICAgfSwKICAgIHsKICAgICAgIlRyYW5zZmVyT2JqZWN0cyI6IHsKICAgICAgICAib2JqZWN0cyI6IFsKICAgICAgICAgIHsKICAgICAgICAgICAgIk5lc3RlZFJlc3VsdCI6IFsKICAgICAgICAgICAgICAwLAogICAgICAgICAgICAgIDAKICAgICAgICAgICAgXQogICAgICAgICAgfQogICAgICAgIF0sCiAgICAgICAgImFkZHJlc3MiOiB7CiAgICAgICAgICAiSW5wdXQiOiAxCiAgICAgICAgfQogICAgICB9CiAgICB9CiAgXQp9",
    //   "address": "0xd5f647edb77d4fda31d0304506447fb3c92e55aaf77bc5ed4b77c332dd4605fa"
    // }

    if (await MethodsUtils.requestApproval(
      transaction,
      method: pRequest.method,
      chainId: pRequest.chainId,
      address: address,
      transportType: pRequest.transportType.name,
      verifyContext: pRequest.verifyContext,
    )) {
      try {
        final keys = GetIt.I<IKeyService>().getKeysForChain(
          chainSupported.chainId,
        );
        final suiPrivateKey = keys[0].privateKey;

        final digest = await _suiClient.signAndExecuteTransaction(
          keyPair: suiPrivateKey,
          networkId: chainSupported.chainId,
          txData: transaction,
        );

        response = response.copyWith(result: {'digest': digest});
      } on PlatformException catch (e) {
        debugPrint('[SampleWallet] suiSignAndExecuteTransaction error $e');
        response = response.copyWith(
          error: JsonRpcError(code: -1, message: '${e.code}: ${e.message}'),
        );
      } catch (e) {
        debugPrint('[SampleWallet] suiSignAndExecuteTransaction error $e');
        final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
        response = response.copyWith(
          error: JsonRpcError(code: error.code, message: error.message),
        );
      }
    } else {
      final error = Errors.getSdkError(Errors.USER_REJECTED);
      response = response.copyWith(
        error: JsonRpcError(code: error.code, message: error.message),
      );
    }

    _handleResponseForTopic(topic, response);
  }

  void _handleResponseForTopic(String topic, JsonRpcResponse response) async {
    final session = _walletKit.sessions.get(topic);

    try {
      await _walletKit.respondSessionRequest(topic: topic, response: response);
      MethodsUtils.handleRedirect(
        topic,
        session!.peer.metadata.redirect,
        response.error?.message,
        response.result != null,
      );
    } on ReownSignError catch (error) {
      MethodsUtils.handleRedirect(
        topic,
        session!.peer.metadata.redirect,
        error.message,
      );
    }
  }

  void _onSessionRequest(SessionRequestEvent? args) async {
    if (args != null && args.chainId == chainSupported.chainId) {
      debugPrint('[SampleWallet] _onSessionRequest ${args.toString()}');
      final handler = suiRequestHandlers[args.method];
      if (handler != null) {
        await handler(args.topic, args.params);
      }
    }
  }

  /// Returns the Sui RPC endpoint
  String get _suiRpcEndpoint {
    if (chainSupported.isTestnet) {
      return 'https://fullnode.testnet.sui.io:443';
    }
    return 'https://fullnode.mainnet.sui.io:443';
  }

  /// Fetches all coin balances with metadata for an address
  Future<List<Map<String, dynamic>>> getTokens({
    required String address,
  }) async {
    try {
      // Get all balances for the address
      final balances = await _getAllBalances(address);
      if (balances.isEmpty) {
        return [];
      }

      final tokens = <Map<String, dynamic>>[];
      for (final balance in balances) {
        final coinType = balance['coinType'] as String;
        final totalBalance = balance['totalBalance'] as String;

        // Fetch metadata for each coin type
        final metadata = await _getCoinMetadata(coinType);
        final decimals = metadata['decimals'] as int? ?? 9;
        final rawAmount = BigInt.parse(totalBalance);
        final quantity = rawAmount / BigInt.from(10).pow(decimals);

        // Fetch price for the coin
        final symbol = metadata['symbol'] ?? _extractCoinSymbol(coinType);
        final price = await _getCoinPrice(symbol.toString().toLowerCase());
        final iconUrl = metadata['iconUrl']?.toString() ?? '';

        tokens.add({
          'name': metadata['name'] ?? _extractCoinName(coinType),
          'symbol': symbol,
          'chainId': chainSupported.chainId,
          'value': (quantity * price).toDouble(),
          'quantity': {
            'decimals': decimals,
            'numeric': '$quantity',
          },
          'iconUrl': iconUrl.isEmpty ? chainSupported.logo : iconUrl,
          'coinType': coinType,
        });
      }

      debugPrint('[SUIService] getTokens found ${tokens.length} coins');
      return tokens;
    } catch (e) {
      debugPrint('[SUIService] getTokens error: $e');
      rethrow;
    }
  }

  /// Fetches coin price from CoinGecko
  Future<double> _getCoinPrice(String symbol) async {
    if (chainSupported.isTestnet) {
      return 0.0;
    }

    // Map of known Sui tokens to their CoinGecko IDs
    const tokenIdMap = {
      'sui': 'sui',
      'usdc': 'usd-coin',
      'usdt': 'tether',
      'weth': 'weth',
      'cetus': 'cetus-protocol',
      'navx': 'navi-protocol',
      'sca': 'scallop-2',
      'buck': 'bucket-protocol',
      'deep': 'deepbook',
    };

    final coinGeckoId = tokenIdMap[symbol];
    if (coinGeckoId == null) {
      return 0.0;
    }

    try {
      final url =
          'https://api.coingecko.com/api/v3/simple/price?ids=$coinGeckoId&vs_currencies=usd';

      final response = await http.get(
        Uri.parse(url),
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tokenData = data[coinGeckoId] as Map<String, dynamic>?;
        final price = tokenData?['usd'] as num?;
        return price?.toDouble() ?? 0.0;
      }
      return 0.0;
    } catch (e) {
      debugPrint('[SUIService] _getCoinPrice error for $symbol: $e');
      return 0.0;
    }
  }

  /// Fetches all balances using suix_getAllBalances RPC method
  Future<List<Map<String, dynamic>>> _getAllBalances(String address) async {
    try {
      final response = await http.post(
        Uri.parse(_suiRpcEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'suix_getAllBalances',
          'params': [address],
        }),
      );

      if (response.statusCode != 200) {
        debugPrint('[SUIService] RPC error: ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null) {
        debugPrint('[SUIService] RPC error: ${data['error']}');
        return [];
      }

      final result = data['result'] as List<dynamic>? ?? [];
      return result.map((b) => b as Map<String, dynamic>).toList();
    } catch (e) {
      debugPrint('[SUIService] _getAllBalances error: $e');
      return [];
    }
  }

  /// Fetches coin metadata using suix_getCoinMetadata RPC method
  Future<Map<String, dynamic>> _getCoinMetadata(String coinType) async {
    try {
      final response = await http.post(
        Uri.parse(_suiRpcEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'suix_getCoinMetadata',
          'params': [coinType],
        }),
      );

      if (response.statusCode != 200) {
        return {};
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['error'] != null || data['result'] == null) {
        return {};
      }

      final result = data['result'] as Map<String, dynamic>;
      return {
        'name': result['name'],
        'symbol': result['symbol'],
        'decimals': result['decimals'],
        'iconUrl': result['iconUrl'],
        'description': result['description'],
      };
    } catch (e) {
      debugPrint('[SUIService] _getCoinMetadata error: $e');
      return {};
    }
  }

  /// Extracts a readable name from the coin type
  String _extractCoinName(String coinType) {
    // coinType format: 0x2::sui::SUI or package::module::name
    final parts = coinType.split('::');
    if (parts.length >= 3) {
      return parts.last;
    }
    return coinType;
  }

  /// Extracts a symbol from the coin type
  String _extractCoinSymbol(String coinType) {
    final name = _extractCoinName(coinType);
    return name.toUpperCase();
  }
}
