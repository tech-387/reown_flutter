import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:reown_appkit/modal/services/analytics_service/i_analytics_service.dart';
import 'package:reown_appkit/modal/services/blockchain_service/i_blockchain_service.dart';
import 'package:reown_appkit/modal/services/coinbase_service/i_coinbase_service.dart';
import 'package:reown_appkit/modal/services/coinbase_service/models/coinbase_events.dart';
import 'package:reown_appkit/modal/services/explorer_service/i_explorer_service.dart';
import 'package:reown_appkit/modal/services/magic_service/i_magic_service.dart';
import 'package:reown_appkit/modal/services/magic_service/models/magic_events.dart';
import 'package:reown_appkit/modal/services/phantom_service/i_phantom_service.dart';
import 'package:reown_appkit/modal/services/phantom_service/models/phantom_events.dart';
import 'package:reown_appkit/modal/services/solflare_service/i_solflare_service.dart';
import 'package:reown_appkit/modal/services/siwe_service/i_siwe_service.dart';
import 'package:reown_appkit/modal/services/solflare_service/models/solflare_events.dart';
import 'package:reown_core/pairing/i_expirer.dart';
import 'package:reown_core/relay_client/i_relay_client.dart';
import 'package:reown_core/store/shared_prefs_store.dart';
import 'package:reown_appkit/modal/services/explorer_service/models/redirect.dart';
import 'package:reown_appkit/modal/services/uri_service/i_url_utils.dart';
import 'package:reown_appkit/modal/utils/platform_utils.dart';

const modalTestMetadata = PairingMetadata(
  name: 'Test wallet',
  description: '',
  url: 'https://example.com',
  icons: [],
  redirect: Redirect(native: 'testwallet://'),
);

SessionData modalTestSession(
  String topic, {
  String? pairingTopic,
  String? selfPublicKey,
}) => SessionData(
  topic: topic,
  pairingTopic: pairingTopic ?? 'pairing-$topic',
  relay: Relay('irn'),
  expiry: 4102444800,
  acknowledged: true,
  controller: 'controller',
  namespaces: const {
    'eip155': Namespace(
      accounts: ['eip155:1:0x0000000000000000000000000000000000000001'],
      methods: ['personal_sign'],
      events: ['accountsChanged', 'chainChanged'],
    ),
  },
  self: ConnectionMetadata(
    publicKey: selfPublicKey ?? 'self-${pairingTopic ?? 'pairing-$topic'}',
    metadata: modalTestMetadata,
  ),
  peer: const ConnectionMetadata(
    publicKey: 'peer',
    metadata: modalTestMetadata,
  ),
);

class ModalTestStorage extends SharedPrefsStores {
  ModalTestStorage() : super(memoryStore: true);
  Future<void> Function(String key)? beforeDelete;
  Future<void> Function(String key, Map<String, dynamic> value)? beforeSet;

  @override
  Future<void> delete(String key) async {
    await super.delete(key);
    await beforeDelete?.call(key);
  }

  @override
  Future<void> set(String key, Map<String, dynamic> value) async {
    await super.set(key, value);
    await beforeSet?.call(key, value);
  }
}

class ModalTestRelay extends Fake implements IRelayClient {
  @override
  bool get isConnected => true;
  @override
  final Event onRelayClientConnect = Event();
  @override
  final Event onRelayClientDisconnect = Event();
  @override
  final Event<ErrorEvent> onRelayClientError = Event();
}

class ModalTestExpirer extends Fake implements IExpirer {
  final expired = <String>[];
  @override
  Future<void> expire(String key) async {
    expired.add(key);
  }
}

class ModalTestAppKit extends ReownAppKit {
  ModalTestAppKit(IReownCore core)
    : super(core: core, metadata: modalTestMetadata);
  final connections = <ConnectResponse>[];
  Future<void> Function(ConnectResponse)? beforeConnectReturn;
  Future<void> Function(String topic)? onDisconnectSession;
  Future<dynamic> Function({
    required String topic,
    required String chainId,
    required SessionRequestParams request,
    RequestPublicationController? publication,
    int? requestId,
  })?
  onRequest;

  @override
  Future<void> init() async {
    await core.storage.init();
    await pairings.init();
    await proposals.init();
    await sessions.init();
  }

  @override
  void registerEventHandler({
    required String chainId,
    required String event,
    void Function(String, dynamic)? handler,
  }) {}

  @override
  Future<ConnectResponse> connect({
    Map<String, RequiredNamespace>? requiredNamespaces,
    Map<String, RequiredNamespace>? optionalNamespaces,
    Map<String, String>? sessionProperties,
    String? pairingTopic,
    List<Relay>? relays,
    List<List<String>>? methods,
    List<SessionAuthRequestParams>? authentication,
    RequestPublicationController? publication,
    int? requestId,
  }) async {
    final index = connections.length;
    final response = ConnectResponse(
      pairingTopic: pairingTopic ?? 'pairing-$index',
      session: Completer<SessionData>(),
      uri: Uri.parse('wc:pairing-${connections.length}@2'),
    );
    connections.add(response);
    final id = requestId ?? index;
    await proposals.set(
      id.toString(),
      ProposalData(
        id: id,
        expiry: 4102444800,
        relays: [Relay('irn')],
        proposer: ConnectionMetadata(
          publicKey: 'self-pairing-$index',
          metadata: modalTestMetadata,
        ),
        requiredNamespaces: {},
        optionalNamespaces: optionalNamespaces ?? {},
        pairingTopic: response.pairingTopic,
      ),
    );
    await pairings.set(
      response.pairingTopic,
      PairingInfo(
        topic: response.pairingTopic,
        expiry: 4102444800,
        relay: Relay('irn'),
        active: false,
      ),
    );
    await beforeConnectReturn?.call(response);
    return response;
  }

  @override
  Future<void> disconnectSession({
    required String topic,
    required ReownSignError reason,
  }) async {
    if (onDisconnectSession != null) {
      await onDisconnectSession!(topic);
      return;
    }
    await super.disconnectSession(topic: topic, reason: reason);
  }

  @override
  Future<dynamic> request({
    required String topic,
    required String chainId,
    required SessionRequestParams request,
    RequestPublicationController? publication,
    int? requestId,
  }) {
    return onRequest!(
      topic: topic,
      chainId: chainId,
      request: request,
      publication: publication,
      requestId: requestId,
    );
  }
}

class ModalTestHarness {
  final uriService = ModalTestUriService();
  final storage = ModalTestStorage();
  final expirer = ModalTestExpirer();
  late final ReownCore core;
  late final ModalTestAppKit appKit;
  late final ReownAppKitModal modal;
  late WidgetTester _tester;

  Future<void> setUp(
    WidgetTester tester, {
    SessionData? restoredSession,
    ISiweService? siweService,
  }) async {
    _tester = tester;
    await GetIt.I.reset();
    core = ReownCore(
      projectId: '0123456789abcdef0123456789abcdef',
      memoryStore: true,
    );
    core.storage = storage;
    core.relayClient = ModalTestRelay();
    core.expirer = expirer;
    appKit = ModalTestAppKit(core);
    await appKit.init();
    await core.linkModeStore.init();
    if (restoredSession != null) {
      await appKit.sessions.set(restoredSession.topic, restoredSession);
      await appKit.pairings.set(
        restoredSession.pairingTopic,
        PairingInfo(
          topic: restoredSession.pairingTopic,
          expiry: 4102444800,
          relay: Relay('irn'),
          active: true,
        ),
      );
    }
    GetIt.I.registerSingleton<IAnalyticsService>(_Analytics());
    GetIt.I.registerSingleton<IExplorerService>(_Explorer());
    GetIt.I.registerSingleton<IUriService>(uriService);
    GetIt.I.registerSingleton<IBlockChainService>(_Blockchain());
    GetIt.I.registerSingleton<IMagicService>(_Magic());
    GetIt.I.registerSingleton<ICoinbaseService>(_Coinbase());
    GetIt.I.registerSingleton<IPhantomService>(_Phantom());
    GetIt.I.registerSingleton<ISolflareService>(_Solflare());
    if (siweService != null) {
      GetIt.I.registerSingleton<ISiweService>(siweService);
    }
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    modal = ReownAppKitModal(
      context: context,
      appKit: appKit,
      enableAnalytics: false,
      disconnectOnDispose: false,
      optionalNamespaces: const {
        'eip155': RequiredNamespace(
          chains: ['eip155:1'],
          methods: ['personal_sign'],
          events: ['accountsChanged', 'chainChanged'],
        ),
      },
    );
    await modal.init();
  }

  Future<void> connect(WidgetTester tester, SessionData session) async {
    await appKit.sessions.set(session.topic, session);
    appKit.onSessionConnect.broadcast(SessionConnect(session));
    await tester.pump();
  }

  Future<void> tearDown() async {
    final disposed = modal.dispose();
    await _tester.pump(const Duration(milliseconds: 600));
    await disposed;
    await GetIt.I.reset();
  }
}

class _Analytics extends Fake implements IAnalyticsService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Explorer extends Fake implements IExplorerService {
  @override
  String getChainIcon(ReownAppKitModalNetworkInfo? chainInfo) => '';
  @override
  ReownAppKitModalWalletInfo? getConnectedWallet() =>
      const ReownAppKitModalWalletInfo(
        listing: AppKitModalWalletListing(
          id: 'test',
          name: 'Test wallet',
          homepage: 'https://example.com',
          imageId: '',
          order: 0,
          mobileLink: 'testwallet://',
        ),
      );
  @override
  WalletRedirect? getWalletRedirect(ReownAppKitModalWalletInfo? walletInfo) =>
      WalletRedirect(mobile: 'testwallet://');
  @override
  Set<String>? get includedWalletIds => null;
  @override
  Set<String>? get excludedWalletIds => null;
  @override
  Future<void> init() async {}
}

class ModalTestUriService extends Fake implements IUriService {
  final launches = <String?>[];
  Object? launchError;
  @override
  Future<bool> openRedirect(
    WalletRedirect redirect, {
    String? wcURI,
    PlatformType? pType,
    AppKitSocialOption? socialOption,
  }) async {
    launches.add(wcURI);
    if (launchError != null) throw launchError!;
    return true;
  }
}

class _Blockchain extends Fake implements IBlockChainService {
  @override
  Future<void> init() async {}
  @override
  void dispose() {}
  @override
  Future<double> getNativeTokenBalance({
    required String address,
    required String namespace,
    required String chainId,
  }) async => 0;
}

class _Magic extends Fake implements IMagicService {
  @override
  Future<void> init({String? chainId}) async {}
  @override
  final Event<MagicConnectEvent> onMagicConnect = Event();
  @override
  final Event<MagicLoginEvent> onMagicLoginSuccess = Event();
  @override
  final Event<MagicErrorEvent> onMagicError = Event();
  @override
  final Event<MagicSessionEvent> onMagicUpdate = Event();
  @override
  final Event<MagicRequestEvent> onMagicRpcRequest = Event();
}

class _Coinbase extends Fake implements ICoinbaseService {
  @override
  Future<void> init() async {}
  @override
  final Event<CoinbaseConnectEvent> onCoinbaseConnect = Event();
  @override
  final Event<CoinbaseErrorEvent> onCoinbaseError = Event();
  @override
  final Event<CoinbaseSessionEvent> onCoinbaseSessionUpdate = Event();
}

class _Phantom extends Fake implements IPhantomService {
  @override
  Future<void> init() async {}
  @override
  final Event<PhantomConnectEvent> onPhantomConnect = Event();
  @override
  final Event<PhantomErrorEvent> onPhantomError = Event();
}

class _Solflare extends Fake implements ISolflareService {
  @override
  Future<void> init() async {}
  @override
  final Event<SolflareConnectEvent> onSolflareConnect = Event();
  @override
  final Event<SolflareErrorEvent> onSolflareError = Event();
}
