import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:reown_appkit/modal/constants/string_constants.dart';
import 'package:reown_appkit/modal/services/siwe_service/i_siwe_service.dart';
import 'package:reown_core/pairing/i_pairing.dart';

import 'shared/appkit_modal_test_harness.dart';

void main() {
  testWidgets('cancelled late connect return survives another cancellation', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    final gate = Completer<void>();
    h.appKit.beforeConnectReturn = (response) async {
      if (response.pairingTopic == 'pairing-0') await gate.future;
    };
    final first = h.modal.buildConnectionUri();
    await tester.pump();
    await h.modal.disconnect();
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    gate.complete();
    await first;
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    expect(h.modal.session, isNull);
    await h.tearDown();
  });

  testWidgets('cancelled A stays cancelled after B connects and is deleted', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    await h.modal.buildConnectionUri();
    await h.connect(tester, modalTestSession('B', pairingTopic: 'pairing-1'));
    expect(h.modal.session?.topic, 'B');
    h.appKit.onSessionDelete.broadcast(SessionDelete('B'));
    await tester.pump();
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    expect(h.modal.session, isNull);
    await h.tearDown();
  });

  for (final reusedPairing in [false, true]) {
    testWidgets(
      'old successful disconnect preserves B (reuse: $reusedPairing)',
      (tester) async {
        final h = ModalTestHarness();
        final siwe = _Siwe();
        await h.setUp(
          tester,
          restoredSession: modalTestSession('A'),
          siweService: siwe,
        );
        final pairing = _DisconnectPairing(h.appKit.pairings);
        h.core.pairing = pairing;
        final gate = Completer<void>();
        h.appKit.onDisconnectSession = (topic) async {
          await gate.future;
          await h.appKit.sessions.delete(topic);
          h.appKit.onSessionDelete.broadcast(SessionDelete(topic));
        };
        final disconnect = h.modal.disconnect();
        await tester.pump();
        h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
        await tester.pump();
        await h.connect(
          tester,
          modalTestSession(
            'B',
            pairingTopic: reusedPairing ? 'pairing-A' : null,
          ),
        );
        gate.complete();
        await disconnect;
        await tester.pump(const Duration(milliseconds: 250));
        expect(h.modal.session?.topic, 'B');
        expect(h.appKit.sessions.get('B'), isNotNull);
        expect(siwe.signOuts, 0);
        expect(pairing.disconnected, reusedPairing ? isEmpty : ['pairing-A']);
        await h.tearDown();
      },
    );
  }

  for (final fails in [false, true]) {
    testWidgets('normal disconnect still cleans A (failure: $fails)', (
      tester,
    ) async {
      final h = ModalTestHarness();
      final siwe = _Siwe();
      await h.setUp(
        tester,
        restoredSession: modalTestSession('A'),
        siweService: siwe,
      );
      h.core.pairing = _DisconnectPairing(h.appKit.pairings);
      h.appKit.onDisconnectSession = (topic) async {
        if (fails) throw StateError('Controlled failure');
        await h.appKit.sessions.delete(topic);
        h.appKit.onSessionDelete.broadcast(SessionDelete(topic));
      };
      await h.modal.disconnect();
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.modal.session, isNull);
      expect(h.appKit.sessions.get('A'), isNull);
      expect(siwe.signOuts, fails ? 0 : 1);
      expect(h.modal.status, ReownAppKitModalStatus.initialized);
      await h.tearDown();
    });
  }

  testWidgets('disconnect does not select replacement after reconnect await', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('A'));
    final gate = Completer<void>();
    h.core.relayClient = _ReconnectRelay(gate.future);
    final disconnected = <String>[];
    h.appKit.onDisconnectSession = (topic) async => disconnected.add(topic);
    final disconnect = h.modal.disconnect();
    await tester.pump();
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump();
    await h.connect(tester, modalTestSession('B'));
    gate.complete();
    await disconnect;
    expect(disconnected, isEmpty);
    expect(h.modal.session?.topic, 'B');
    expect(h.appKit.sessions.get('B'), isNotNull);
    await h.tearDown();
  });

  for (final topic in ['A', 'B']) {
    testWidgets(
      'chain/account events forward; only current $topic has effects',
      (tester) async {
        final h = ModalTestHarness();
        final siwe = _Siwe();
        await h.setUp(
          tester,
          restoredSession: modalTestSession('B'),
          siweService: siwe,
        );
        siwe.enabled = true;
        final events = <SessionEvent?>[];
        h.modal.onSessionEventEvent.subscribe(events.add);
        final chainBefore = h.modal.selectedChain?.chainId;
        final chainEvent = SessionEvent(
          1,
          topic,
          'chainChanged',
          'eip155:8453',
          8453,
        );
        final accountEvent = SessionEvent(
          2,
          topic,
          'accountsChanged',
          'eip155:8453',
          ['0x123'],
        );
        h.appKit.onSessionEvent.broadcast(chainEvent);
        h.appKit.onSessionEvent.broadcast(accountEvent);
        await tester.pump();
        expect(events, [chainEvent, accountEvent]);
        expect(
          h.modal.selectedChain?.chainId,
          topic == 'B' ? 'eip155:8453' : chainBefore,
        );
        expect(siwe.signOuts, topic == 'B' ? 1 : 0);
        await h.tearDown();
      },
    );
  }

  testWidgets('event forwarding can invalidate ownership before side effects', (
    tester,
  ) async {
    final h = ModalTestHarness();
    final siwe = _Siwe();
    await h.setUp(
      tester,
      restoredSession: modalTestSession('A'),
      siweService: siwe,
    );
    siwe.enabled = true;
    h.modal.onSessionEventEvent.subscribe((_) {
      h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    });
    h.appKit.onSessionEvent.broadcast(
      SessionEvent(1, 'A', 'accountsChanged', 'eip155:1', ['0x123']),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(siwe.signOuts, 0);
    await h.tearDown();
  });

  testWidgets('restores stored session and accepts its update/delete', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('A'));
    expect(h.modal.session?.topic, 'A');
    final updated = modalTestSession('A').namespaces;
    h.appKit.onSessionUpdate.broadcast(SessionUpdate(1, 'A', updated));
    await tester.pump();
    expect(h.modal.session?.topic, 'A');
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(h.modal.session, isNull);
    await h.tearDown();
  });

  testWidgets('old delete does not clear newer session', (tester) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('B'));
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets('old update does not replace newer session', (tester) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('B'));
    await h.appKit.sessions.set('A', modalTestSession('A'));
    h.appKit.onSessionUpdate.broadcast(
      SessionUpdate(1, 'A', modalTestSession('A').namespaces),
    );
    await tester.pump();
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets('old connection error cannot expire newer pairing', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.buildConnectionUri();
    h.appKit.connections.first.session.completeError(
      ReownSignError(code: 5000, message: 'Rejected'),
    );
    await tester.pump();
    expect(h.expirer.expired, isNot(contains('pairing-1')));
    await h.tearDown();
  });

  testWidgets('old connect event cannot replace newer pending connection', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.buildConnectionUri();
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    expect(h.modal.session, isNull);
    await h.connect(tester, modalTestSession('B', pairingTopic: 'pairing-1'));
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets(
    'delete started before connect cannot clear newer session after await',
    (tester) async {
      final h = ModalTestHarness();
      await h.setUp(tester, restoredSession: modalTestSession('A'));
      final gate = Completer<void>();
      h.storage.beforeDelete = (key) async {
        if (key == StorageConstants.selectedChainId) await gate.future;
      };
      h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
      await tester.pump();
      await h.connect(tester, modalTestSession('B'));
      gate.complete();
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.modal.session?.topic, 'B');
      expect(
        h.storage.get(StorageConstants.modalSession)?['sessionData']?['topic'],
        'B',
      );
      await h.tearDown();
    },
  );
  testWidgets('cancelled pending connection cannot later settle', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    await h.appKit.proposals.delete('0');
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    expect(h.modal.session, isNull);
    await h.tearDown();
  });

  testWidgets('delayed old connection cannot replace newer connection URI', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    final gate = Completer<void>();
    h.appKit.beforeConnectReturn = (response) async {
      if (response.pairingTopic == 'pairing-0') await gate.future;
    };
    final first = h.modal.buildConnectionUri();
    await tester.pump();
    await h.modal.buildConnectionUri();
    gate.complete();
    await first;
    expect(h.modal.wcUri, 'wc:pairing-1@2');
    await h.tearDown();
  });

  for (final updating in [false, true]) {
    testWidgets(
      'stale ${updating ? 'update' : 'connect'} cannot emit after storage await',
      (tester) async {
        final h = ModalTestHarness();
        await h.setUp(
          tester,
          restoredSession: updating ? modalTestSession('A') : null,
        );
        final gate = Completer<void>();
        h.storage.beforeSet = (key, value) async {
          if (key == StorageConstants.modalSession &&
              value['sessionData']?['topic'] == 'A') {
            await gate.future;
          }
        };
        final connected = <String?>[];
        final updated = <String?>[];
        h.modal.onModalConnect.subscribe(
          (event) => connected.add(event.session.topic),
        );
        h.modal.onModalUpdate.subscribe(
          (event) => updated.add(event.session.topic),
        );
        if (updating) {
          h.appKit.onSessionUpdate.broadcast(
            SessionUpdate(1, 'A', modalTestSession('A').namespaces),
          );
          await tester.pump();
        } else {
          await h.connect(tester, modalTestSession('A'));
        }
        h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
        await tester.pump();
        await h.connect(tester, modalTestSession('B'));
        gate.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(h.modal.session?.topic, 'B');
        expect(connected, ['B']);
        expect(updated, isEmpty);
        await h.tearDown();
      },
    );
  }

  testWidgets(
    'expiry retains original topic and never clears different session',
    (tester) async {
      final h = ModalTestHarness();
      await h.setUp(tester, restoredSession: modalTestSession('B'));
      final expired = <String?>[];
      h.modal.onSessionExpireEvent.subscribe(
        (event) => expired.add(event.topic),
      );
      h.appKit.onSessionExpire.broadcast(SessionExpire('A'));
      await tester.pump();
      expect(h.modal.session?.topic, 'B');
      expect(expired, ['A']);
      await h.tearDown();
    },
  );

  testWidgets('old auth response cannot replace newer session', (tester) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('B'));
    h.appKit.onSessionAuthResponse.broadcast(
      SessionAuthResponse(id: 1, topic: 'A', session: modalTestSession('A')),
    );
    await tester.pump();
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets(
    'auth response cannot act after its session was deleted during settle',
    (tester) async {
      final h = ModalTestHarness();
      await h.setUp(tester);
      await h.modal.buildConnectionUri();
      final gate = Completer<void>();
      h.storage.beforeSet = (key, value) async {
        if (key == StorageConstants.modalSession &&
            value['sessionData']?['topic'] == 'A') {
          await gate.future;
        }
      };
      h.appKit.onSessionAuthResponse.broadcast(
        SessionAuthResponse(
          id: 1,
          topic: 'A',
          session: modalTestSession('A', pairingTopic: 'pairing-0'),
        ),
      );
      await tester.pump();
      h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
      await tester.pump();
      await h.connect(tester, modalTestSession('B'));
      gate.complete();
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.modal.session?.topic, 'B');
      await h.tearDown();
    },
  );

  testWidgets('base connection after cancelled modal attempt is accepted', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    await h.connect(tester, modalTestSession('B'));
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets('fresh base proposal can reuse cancelled modal pairing', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    final pairing = h.appKit.connections.single.pairingTopic;
    await h.modal.disconnect();
    final fresh = await h.appKit.connect(pairingTopic: pairing);
    final session = modalTestSession(
      'B',
      pairingTopic: fresh.pairingTopic,
      selfPublicKey: 'self-pairing-1',
    );
    fresh.session.complete(session);
    await h.connect(tester, session);
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });

  testWidgets('deleting settling modal session releases its attempt', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    final gate = Completer<void>();
    h.storage.beforeSet = (key, value) async {
      if (key == StorageConstants.modalSession &&
          value['sessionData']?['topic'] == 'A') {
        await gate.future;
      }
    };
    final connected = <String?>[];
    h.modal.onModalConnect.subscribe(
      (event) => connected.add(event.session.topic),
    );
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump();
    await h.connect(tester, modalTestSession('B'));
    gate.complete();
    await tester.pump(const Duration(milliseconds: 250));
    expect(h.modal.session?.topic, 'B');
    expect(connected, ['B']);
    await h.tearDown();
  });

  testWidgets(
    'cancellation while connect is pending rejects its late session',
    (tester) async {
      final h = ModalTestHarness();
      await h.setUp(tester);
      final gate = Completer<void>();
      h.appKit.beforeConnectReturn = (_) => gate.future;
      final connection = h.modal.buildConnectionUri();
      await tester.pump();
      await h.modal.disconnect();
      gate.complete();
      await connection;
      await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
      expect(h.modal.session, isNull);
      await h.tearDown();
    },
  );
  testWidgets('successful modal pairing remains reusable by base connect', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    h.modal.closeModal();
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump();
    await h.connect(tester, modalTestSession('B', pairingTopic: 'pairing-0'));
    expect(h.modal.session?.topic, 'B');
    await h.tearDown();
  });
  for (final deleteOldSession in [false, true]) {
    testWidgets(
      'new attempt during old session storage keeps ownership (delete: $deleteOldSession)',
      (tester) async {
        final h = ModalTestHarness();
        await h.setUp(tester);
        await h.modal.buildConnectionUri();
        final gate = Completer<void>();
        h.storage.beforeSet = (key, value) async {
          if (key == StorageConstants.modalSession &&
              value['sessionData']?['topic'] == 'A') {
            await gate.future;
          }
        };
        final connected = <String>[];
        h.modal.onModalConnect.subscribe(
          (event) => connected.add(event.session.topic!),
        );
        await h.connect(
          tester,
          modalTestSession('A', pairingTopic: 'pairing-0'),
        );
        await h.modal.buildConnectionUri();
        if (deleteOldSession) {
          h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
          await tester.pump();
        }
        gate.complete();
        await tester.pump();
        expect(connected, isEmpty);
        await h.connect(
          tester,
          modalTestSession('B', pairingTopic: 'pairing-1'),
        );
        expect(h.modal.session?.topic, 'B');
        expect(connected, ['B']);
        await h.tearDown();
      },
    );
  }
  testWidgets(
    'same-session update during connect preserves connect notification',
    (tester) async {
      final h = ModalTestHarness();
      await h.setUp(tester);
      final gate = Completer<void>();
      var paused = false;
      h.storage.beforeSet = (key, value) async {
        if (!paused && key == StorageConstants.modalSession) {
          paused = true;
          await gate.future;
        }
      };
      final connected = <ReownAppKitModalSession>[];
      h.modal.onModalConnect.subscribe((event) => connected.add(event.session));
      await h.connect(tester, modalTestSession('A'));
      h.appKit.onSessionUpdate.broadcast(
        SessionUpdate(1, 'A', modalTestSession('A').namespaces),
      );
      await tester.pump();
      final updated = h.modal.session;
      gate.complete();
      await tester.pump();
      expect(connected, [same(updated)]);
      await h.tearDown();
    },
  );
  for (final replaceSession in [false, true]) {
    testWidgets(
      'failed auth disconnect cleans only original session (replace: $replaceSession)',
      (tester) async {
        final h = ModalTestHarness();
        await h.setUp(tester);
        final gate = Completer<void>();
        final disconnected = <String>[];
        h.appKit.onDisconnectSession = (topic) async {
          disconnected.add(topic);
          await gate.future;
          throw StateError('Controlled disconnect failure');
        };
        await h.appKit.sessions.set('A', modalTestSession('A'));
        h.appKit.onSessionAuthResponse.broadcast(
          SessionAuthResponse(
            id: 1,
            topic: 'A',
            session: modalTestSession('A'),
          ),
        );
        await tester.pump();
        expect(disconnected, ['A']);
        if (replaceSession) {
          h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
          await tester.pump();
          await h.connect(tester, modalTestSession('B'));
        }
        gate.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
        expect(h.appKit.sessions.get('A'), isNull);
        expect(h.modal.session?.topic, replaceSession ? 'B' : null);
        if (replaceSession) expect(h.appKit.sessions.get('B'), isNotNull);
        await h.tearDown();
      },
    );
  }

  testWidgets('two cancelled attempts cannot revive the first', (tester) async {
    final h = ModalTestHarness();
    await h.setUp(tester);
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    await h.modal.buildConnectionUri();
    await h.modal.disconnect();
    await h.connect(tester, modalTestSession('A', pairingTopic: 'pairing-0'));
    final topic = h.modal.session?.topic;
    await h.tearDown();
    expect(
      topic,
      isNull,
      reason: 'Cancelled A must remain cancelled after B is cancelled',
    );
  });

  testWidgets('failed old disconnect cannot delete replacement', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('A'));
    final gate = Completer<void>();
    h.appKit.onDisconnectSession = (topic) async {
      await gate.future;
      throw StateError('Original disconnect failed');
    };
    final disconnect = h.modal.disconnect();
    await tester.pump();
    h.appKit.onSessionDelete.broadcast(SessionDelete('A'));
    await tester.pump();
    await h.connect(tester, modalTestSession('B'));
    expect(h.modal.session?.topic, 'B');
    gate.complete();
    await disconnect;
    await tester.pump(const Duration(milliseconds: 250));
    final topic = h.modal.session?.topic;
    final stored = h.appKit.sessions.get('B');
    await h.tearDown();
    expect(topic, 'B', reason: 'Failure belongs to A');
    expect(stored, isNotNull);
  });

  testWidgets('old chain event cannot change replacement chain', (
    tester,
  ) async {
    final h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('B'));
    final chainBefore = h.modal.selectedChain?.chainId;
    h.appKit.onSessionEvent.broadcast(
      SessionEvent(1, 'A', 'chainChanged', 'eip155:8453', 8453),
    );
    await tester.pump();
    final chainAfter = h.modal.selectedChain?.chainId;
    await h.tearDown();
    expect(chainAfter, chainBefore, reason: 'A is not the current session');
  });
}

class _Siwe extends Fake implements ISiweService {
  @override
  bool enabled = false;
  @override
  SIWEConfig? get config => null;
  @override
  bool get signOutOnDisconnect => true;
  @override
  bool get signOutOnAccountChange => true;
  int signOuts = 0;
  @override
  Future<void> signOut() async => signOuts++;
}

class _DisconnectPairing extends Fake implements IPairing {
  _DisconnectPairing(this.store);
  final IPairingStore store;
  final disconnected = <String>[];
  @override
  IPairingStore getStore() => store;
  @override
  Future<void> disconnect({required String topic}) async {
    disconnected.add(topic);
    await store.delete(topic);
  }
}

class _ReconnectRelay extends ModalTestRelay {
  _ReconnectRelay(this.reconnected);
  final Future<void> reconnected;
  bool connected = false;
  @override
  bool get isConnected => connected;
  @override
  Future<void> connect({String? relayUrl}) async {
    await reconnected;
    connected = true;
  }
}
