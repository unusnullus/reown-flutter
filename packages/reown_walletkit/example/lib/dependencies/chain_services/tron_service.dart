import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:on_chain/on_chain.dart' as on_chain;
import 'package:reown_walletkit/reown_walletkit.dart';

import 'package:reown_walletkit_wallet/dependencies/i_walletkit_service.dart';
import 'package:reown_walletkit_wallet/dependencies/key_service/i_key_service.dart';
import 'package:reown_walletkit_wallet/models/chain_metadata.dart';
import 'package:reown_walletkit_wallet/utils/methods_utils.dart';

class TronService {
  late final ReownWalletKit _walletKit;
  late final TronApi _tronApi;

  final ChainMetadata chainSupported;

  Map<String, dynamic Function(String, dynamic)> get tronRequestHandlers => {
        'tron_signMessage': tronSignMessage,
        'tron_signTransaction': tronSignTransaction,
        'tron_sendTransaction': tronSendTransaction,
        'tron_getBalance': tronGetBalance,
      };

  TronService({required this.chainSupported}) {
    _walletKit = GetIt.I<IWalletKitService>().walletKit;
    _tronApi = TronApi(chainSupported: chainSupported);

    for (var handler in tronRequestHandlers.entries) {
      _walletKit.registerRequestHandler(
        chainId: chainSupported.chainId,
        method: handler.key,
        handler: handler.value,
      );
    }
  }

  TronApi get tronApi => _tronApi;

  Future<void> tronSignMessage(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] tronSignMessage: $parameters');
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
        // Convert signature to hex string (r, s, v) -> 65 bytes
        final signatureHex = await signMessage(message);
        response = response.copyWith(
          result: {
            'signature': signatureHex,
          },
        );
      } else {
        final error = Errors.getSdkError(Errors.USER_REJECTED);
        response = response.copyWith(
          error: JsonRpcError(code: error.code, message: error.message),
        );
      }
    } catch (e) {
      debugPrint('[SampleWallet] tronSignMessage error $e');
      final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
      response = response.copyWith(
        error: JsonRpcError(code: error.code, message: error.message),
      );
    }

    _handleResponseForTopic(topic, response);
  }

  Future<String> signMessage(String message) async {
    try {
      final keys = GetIt.I<IKeyService>().getKeysForChain(
        chainSupported.chainId,
      );

      final privateKeyHex = keys[0].privateKey;
      final signer = on_chain.TronPrivateKey(privateKeyHex);

      final msgBytes = Uint8List.fromList(message.codeUnits);
      return signer.signPersonalMessage(msgBytes);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> tronSignTransaction(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] tronSignTransaction: ${jsonEncode(parameters)}');
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    final params = parameters as Map<String, dynamic>;
    final address = params['address'] as String;
    final txJson = extractTransactionFromParams(parameters);
    if (txJson == null) {
      final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
      response = response.copyWith(
        error: JsonRpcError(
          code: error.code,
          message: 'Missing transaction parameter',
        ),
      );
      _handleResponseForTopic(topic, response);
      return;
    }

    const encoder = JsonEncoder.withIndent('  ');
    final message = encoder.convert(txJson);
    if (await MethodsUtils.requestApproval(
      message,
      method: pRequest.method,
      chainId: pRequest.chainId,
      address: address,
      transportType: pRequest.transportType.name,
      verifyContext: pRequest.verifyContext,
    )) {
      try {
        final hexSignature = await signTransaction(txJson);
        txJson['signature'] = [hexSignature];

        // Return signed tx
        response = response.copyWith(result: txJson);
      } catch (e) {
        debugPrint('[SampleWallet] tronSignTransaction error $e');
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

  Map<String, dynamic>? extractTransactionFromParams(dynamic parameters) {
    final params = parameters as Map<String, dynamic>;
    final transaction = params['transaction'] as Map<String, dynamic>?;
    return transaction?['transaction'] ?? transaction;
  }

  Future<String> signTransaction(Map<String, dynamic> transaction) async {
    try {
      final keys = GetIt.I<IKeyService>().getKeysForChain(
        chainSupported.chainId,
      );
      final privateKeyHex = keys[0].privateKey;
      final privateKey = on_chain.TronPrivateKey(privateKeyHex);

      final tronTx = on_chain.Transaction.fromJson(transaction);
      final txBytes = tronTx.rawData.toBuffer();

      final signature = privateKey.sign(txBytes);
      return bytesToHex(signature, include0x: true);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> tronSendTransaction(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] tronSendTransaction: ${jsonEncode(parameters)}');
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    final params = parameters as Map<String, dynamic>;
    final address = params['address'] as String;
    final txJson = extractTransactionFromParams(parameters);
    if (txJson == null) {
      final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
      response = response.copyWith(
        error: JsonRpcError(
          code: error.code,
          message: 'Missing transaction parameter',
        ),
      );
      _handleResponseForTopic(topic, response);
      return;
    }

    const encoder = JsonEncoder.withIndent('  ');
    final message = encoder.convert(txJson);
    if (await MethodsUtils.requestApproval(
      message,
      method: pRequest.method,
      chainId: pRequest.chainId,
      address: address,
      transportType: pRequest.transportType.name,
      verifyContext: pRequest.verifyContext,
    )) {
      try {
        // Sign the transaction
        final hexSignature = await signTransaction(txJson);
        txJson['signature'] = [hexSignature];

        // Broadcast the signed transaction to the network
        final txHash = await _tronApi.broadcastTransaction(txJson);
        response = response.copyWith(result: {
          'result': true,
          'txid': txHash,
        });
      } catch (e) {
        debugPrint('[SampleWallet] tronSendTransaction error $e');
        final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
        response = response.copyWith(
          error: JsonRpcError(code: error.code, message: '$e'),
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

  Future<void> tronGetBalance(String topic, dynamic parameters) async {
    debugPrint('[SampleWallet] tronGetBalance: ${jsonEncode(parameters)}');
    final pRequest = _walletKit.pendingRequests.getAll().last;
    var response = JsonRpcResponse(id: pRequest.id, jsonrpc: '2.0');

    try {
      final params = parameters as Map<String, dynamic>;
      final address = params['address'] as String;

      // Fetch balance in sun (1 TRX = 1,000,000 sun)
      final balanceInSun = await getBalance(address: address);
      response = response.copyWith(result: {
        'balance': balanceInSun.toString(),
      });
    } catch (e) {
      debugPrint('[SampleWallet] tronGetBalance error $e');
      final error = Errors.getSdkError(Errors.MALFORMED_REQUEST_PARAMS);
      response = response.copyWith(
        error: JsonRpcError(code: error.code, message: '$e'),
      );
    }

    _handleResponseForTopic(topic, response);
  }

  Future<int> getBalance({required String address}) async {
    return await _tronApi.getBalanceInSun(address: address);
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
}

class TronApi {
  final ChainMetadata chainSupported;

  TronApi({required this.chainSupported});

  String get _apiEndpoint => chainSupported.isTestnet
      ? 'https://nile.trongrid.io'
      : 'https://api.trongrid.io';

  String get _tronscanApiEndpoint => chainSupported.isTestnet
      ? 'https://nileapi.tronscan.org/api'
      : 'https://apilist.tronscanapi.com/api';

  Future<int> getBalanceInSun({required String address}) async {
    final blockResponse = await http.get(
      Uri.parse('$_apiEndpoint/walletsolidity/getnowblock'),
    );
    final blockID = jsonDecode(blockResponse.body)['blockID'] as String;
    final blockNumber = jsonDecode(blockResponse.body)['block_header']
        ['raw_data']['number'] as num;

    final url = '$_apiEndpoint/wallet/getaccountbalance';
    final response = await http.post(
      Uri.parse(url),
      body: jsonEncode({
        'account_identifier': {'address': address},
        'block_identifier': {'hash': blockID, 'number': blockNumber},
        'visible': true,
      }),
      headers: {'accept': 'application/json'},
    );

    final parsedResponse = jsonDecode(response.body) as Map<String, dynamic>;
    final balance = parsedResponse['balance'] as int? ?? 0;
    debugPrint('[TronApi] getBalanceInSun $balance');
    return balance;
  }

  Future<String> broadcastTransaction(Map<String, dynamic> signedTx) async {
    final url = '$_apiEndpoint/wallet/broadcasttransaction';
    final response = await http.post(
      Uri.parse(url),
      body: jsonEncode(signedTx),
      headers: {
        'accept': 'application/json',
        'content-type': 'application/json',
      },
    );

    final parsedResponse = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('[TronApi] broadcastTransaction ${response.body}');

    if (parsedResponse['result'] == true) {
      return parsedResponse['txid'] as String;
    } else {
      final errorMessage =
          parsedResponse['message'] ?? 'Failed to broadcast transaction';
      throw Exception(errorMessage);
    }
  }

  Future<Map<String, dynamic>> getAccount({required String address}) async {
    final url = '$_apiEndpoint/wallet/getaccount';
    final response = await http.post(
      Uri.parse(url),
      body: jsonEncode({'address': address, 'visible': true}),
      headers: {'accept': 'application/json'},
    );
    try {
      debugPrint('[TronApi] getAccount ${response.body}');
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint(e.toString());
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getTokens({
    required String address,
  }) async {
    try {
      final url = '$_apiEndpoint/v1/accounts/$address';
      final response = await http.get(Uri.parse(url));
      final parsedResponse = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[TronApi] getTokens parsedResponse $parsedResponse');
      final data = parsedResponse['data'] as List;
      if (data.isEmpty) {
        return [];
      }
      final firstData = data.first as Map<String, dynamic>;
      final tokens = <Map<String, dynamic>>[];

      // Add native TRX balance first
      final trxBalanceInSun = firstData['balance'] as int? ?? 0;
      if (trxBalanceInSun > 0) {
        const trxDecimals = 6; // TRX has 6 decimals (1 TRX = 1,000,000 sun)
        final trxQuantity = trxBalanceInSun / 1000000.0;

        // Fetch TRX price from TRONSCAN
        final trxPrice = await _getTrxPrice();

        tokens.add({
          'name': 'Tronix',
          'symbol': 'TRX',
          'chainId': chainSupported.chainId,
          'value': trxQuantity * trxPrice,
          'quantity': {
            'decimals': trxDecimals,
            'numeric': '$trxQuantity',
          },
          'iconUrl': 'https://static.tronscan.org/production/logo/trx.png',
        });
      }

      // Add TRC20 tokens
      final trc20List = firstData['trc20'] as List<dynamic>? ?? [];
      debugPrint('[TronApi] getTokens trc20List $trc20List');
      for (final tokenEntry in trc20List) {
        final tokenMap = Map<String, String>.from(tokenEntry);
        final contractAddress = tokenMap.keys.first;
        final rawBalance = BigInt.parse(tokenMap.values.first);

        // Fetch token metadata from TRONSCAN API
        final tokenInfo = await getTokenInfo(contractAddress: contractAddress);
        final decimals = tokenInfo['decimals'] ?? 0;
        final quantity = rawBalance / BigInt.from(10).pow(decimals);
        final price = tokenInfo['price'] ?? 0.0;
        tokens.add({
          'name': tokenInfo['name'] ?? 'Unknown',
          'symbol': tokenInfo['symbol'] ?? 'Unknown',
          'chainId': chainSupported.chainId,
          'value': (quantity * price).toDouble(),
          'quantity': {
            'decimals': decimals,
            'numeric': '$quantity',
          },
          'iconUrl': tokenInfo['iconUrl'],
        });
      }

      debugPrint('[TronApi] getTokens found ${tokens.length} tokens');
      return tokens;
    } catch (e) {
      debugPrint('[TronApi] getTokens error: $e');
      rethrow;
    }
  }

  /// Fetches the current TRX price in USD from TRONSCAN
  Future<double> _getTrxPrice() async {
    try {
      final url = '$_tronscanApiEndpoint/token?id=_&showAll=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        return 0.0;
      }

      final parsedResponse = jsonDecode(response.body) as Map<String, dynamic>;
      final data = parsedResponse['data'] as List?;
      if (data == null || data.isEmpty) {
        return 0.0;
      }

      // Find TRX in the token list
      for (final token in data) {
        final tokenMap = token as Map<String, dynamic>;
        if (tokenMap['abbr'] == 'TRX' || tokenMap['tokenId'] == '_') {
          final priceInTrx = tokenMap['priceInTrx'] as num?;
          if (priceInTrx != null && priceInTrx > 0) {
            return 1.0 / priceInTrx.toDouble(); // Convert TRX price to USD
          }
        }
      }

      return 0.0;
    } catch (e) {
      debugPrint('[TronApi] _getTrxPrice error: $e');
      return 0.0;
    }
  }

  Future<Map<String, dynamic>> getTokenInfo({
    required String contractAddress,
  }) async {
    try {
      // Use TRONSCAN API for comprehensive token metadata including icon
      final url = '$_tronscanApiEndpoint/token_trc20?contract=$contractAddress';
      final response = await http.get(
        Uri.parse(url),
        headers: {'accept': 'application/json'},
      );
      final parsedResponse = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[TronApi] getTokenInfo response: $parsedResponse');

      final tokenList = parsedResponse['trc20_tokens'] as List?;
      if (tokenList == null || tokenList.isEmpty) {
        return {};
      }

      final tokenData = tokenList.first as Map<String, dynamic>;
      final priceUsd =
          (tokenData['tokenPriceLine']['data'] as List).last['priceUsd'] ??
              '0.0';
      return {
        'name': tokenData['name'] as String?,
        'symbol': tokenData['symbol'] as String?,
        'price': double.tryParse(tokenData['price']) ?? double.parse(priceUsd),
        'decimals': tokenData['decimals'] as int?,
        'iconUrl': tokenData['icon_url'] as String?,
      };
    } catch (e) {
      debugPrint('[TronApi] getTokenInfo error for $contractAddress: $e');
      return {};
    }
  }

  double parsedBalance(int rawBalance) {
    return rawBalance / 1000000.0;
  }
}

// class TronToken {
//   final String contractAddress;
//   final String name;
//   final String symbol;
//   final int decimals;
//   final BigInt rawBalance;
//   final String? iconUrl;
//   final String? description;

//   TronToken({
//     required this.contractAddress,
//     required this.name,
//     required this.symbol,
//     required this.decimals,
//     required this.rawBalance,
//     this.iconUrl,
//     this.description,
//   });

//   double get balance {
//     if (decimals == 0) return rawBalance.toDouble();
//     return rawBalance / BigInt.from(10).pow(decimals);
//   }

//   @override
//   String toString() {
//     return 'TronToken(name: $name, symbol: $symbol, balance: $balance, '
//         'contractAddress: $contractAddress, iconUrl: $iconUrl)';
//   }
// }
