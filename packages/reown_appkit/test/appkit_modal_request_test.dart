import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reown_appkit/reown_appkit.dart';

import 'shared/appkit_modal_test_harness.dart';

void main() {
  late ModalTestHarness h;
  const params = SessionRequestParams(method: 'personal_sign', params: []);

  Future<void> setUpModal(WidgetTester tester) async {
    h = ModalTestHarness();
    await h.setUp(tester, restoredSession: modalTestSession('original'));
  }

  Future<void> dispose(WidgetTester tester) async {
    await h.tearDown();
    await tester.pump(const Duration(seconds: 1));
  }

  for (final error in [
    const ReownSignError(code: 5100, message: 'Unsupported request'),
    const ReownSignError(code: 5000, message: 'User rejected request'),
  ]) {
    testWidgets('preserves error and stack: ${error.message}', (tester) async {
      await setUpModal(tester);
      final originalStack = StackTrace.fromString('original Sign failure');
      h.appKit.onRequest =
          ({
            required topic,
            required chainId,
            required request,
            publication,
            requestId,
          }) => Future.error(error, originalStack);
      final notifications = <ModalError>[];
      h.modal.onModalError.subscribe((event) => notifications.add(event));

      Object? caught;
      StackTrace? caughtStack;
      try {
        await h.modal.request(
          topic: 'original',
          chainId: 'eip155:1',
          request: params,
        );
      } catch (e, s) {
        caught = e;
        caughtStack = s;
      }
      expect(caught, same(error));
      expect(caughtStack.toString(), originalStack.toString());
      expect(notifications, hasLength(1));
      expect(notifications.single.message, error.message);
      if (error.code == 5000) {
        expect(notifications.single, isA<UserRejectedRequest>());
      }
      await dispose(tester);
    });
  }

  testWidgets('local cancellation is not wallet rejection', (tester) async {
    await setUpModal(tester);
    h.appKit.onRequest =
        ({
          required topic,
          required chainId,
          required request,
          publication,
          requestId,
        }) async {
          throw const RequestPublicationCancelled();
        };
    final notifications = <ModalError>[];
    h.modal.onModalError.subscribe((event) => notifications.add(event));
    await expectLater(
      h.modal.request(topic: 'original', chainId: 'eip155:1', request: params),
      throwsA(isA<RequestPublicationCancelled>()),
    );
    expect(notifications, isEmpty);
    await dispose(tester);
  });

  testWidgets('controlled request launches original ID only after ACK', (
    tester,
  ) async {
    await setUpModal(tester);
    final controller = RequestPublicationController();
    final response = Completer<dynamic>();
    h.appKit.onRequest =
        ({
          required topic,
          required chainId,
          required request,
          publication,
          requestId,
        }) {
          expect(publication, same(controller));
          expect(requestId, 123);
          expect(topic, 'original');
          return response.future;
        };
    final IReownAppKitModal modal = h.modal;
    final result = modal.request(
      topic: 'original',
      chainId: 'eip155:1',
      request: params,
      publication: controller,
      requestId: 123,
    );
    await tester.pump();
    expect(h.uriService.launches, isEmpty);
    controller.beginSend();
    controller.acknowledge();
    await tester.pump();
    expect(h.uriService.launches, ['requestId=123&sessionTopic=original']);
    response.complete('signed-result');
    expect(await result, 'signed-result');
    await dispose(tester);
  });

  for (final stop in ['cancel', 'response', 'error', 'session']) {
    testWidgets('$stop before ACK prevents later wallet launch', (
      tester,
    ) async {
      await setUpModal(tester);
      final publication = RequestPublicationController();
      final response = Completer<dynamic>();
      h.appKit.onRequest =
          ({
            required topic,
            required chainId,
            required request,
            publication,
            requestId,
          }) => response.future;
      final result = h.modal.request(
        topic: 'original',
        chainId: 'eip155:1',
        request: params,
        publication: publication,
        requestId: 124,
      );
      // Always observe the original response, including an error before ACK.
      final observed = result.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      publication.beginSend();
      if (stop == 'cancel') {
        expect(publication.cancel(), isFalse);
      } else if (stop == 'response') {
        response.complete('original-result');
      } else if (stop == 'error') {
        response.completeError(
          const ReownSignError(code: 5100, message: 'Request failed'),
        );
      } else {
        h.appKit.onSessionDelete.broadcast(SessionDelete('original', id: 9));
        await tester.pump();
        await h.connect(tester, modalTestSession('replacement'));
        expect(h.modal.session?.topic, 'replacement');
      }
      await tester.pump();
      publication.acknowledge();
      await tester.pump();
      expect(h.uriService.launches, isEmpty);
      if (!response.isCompleted) response.complete('original-result');
      final value = await observed;
      expect(
        value,
        stop == 'error' ? isA<ReownSignError>() : 'original-result',
      );
      await dispose(tester);
    });
  }

  testWidgets('uncontrolled requests retain normal result and wallet launch', (
    tester,
  ) async {
    await setUpModal(tester);
    h.appKit.onRequest =
        ({
          required topic,
          required chainId,
          required request,
          publication,
          requestId,
        }) async => 'legacy-result';
    expect(
      await h.modal.request(
        topic: 'original',
        chainId: 'eip155:1',
        request: params,
      ),
      'legacy-result',
    );
    expect(h.uriService.launches.single, contains('sessionTopic=original'));
    await dispose(tester);
  });

  testWidgets(
    'expiry after sending prevents delayed launch but keeps response',
    (tester) async {
      await setUpModal(tester);
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2;
      final publication = RequestPublicationController(expiryTimestamp: expiry);
      final response = Completer<dynamic>();
      h.appKit.onRequest =
          ({
            required topic,
            required chainId,
            required request,
            publication,
            requestId,
          }) => response.future;
      final result = h.modal.request(
        topic: 'original',
        chainId: 'eip155:1',
        request: params,
        publication: publication,
      );
      publication.beginSend();
      await tester.runAsync(
        () => Future<void>.delayed(
          Duration(
            milliseconds:
                expiry * 1000 - DateTime.now().millisecondsSinceEpoch + 1,
          ),
        ),
      );
      publication.acknowledge();
      await tester.pump();
      expect(h.uriService.launches, isEmpty);
      response.complete('original-result');
      expect(await result, 'original-result');
      await dispose(tester);
    },
  );

  testWidgets(
    'cancellation before sending neither launches nor reports rejection',
    (tester) async {
      await setUpModal(tester);
      final publication = RequestPublicationController()..cancel();
      h.appKit.onRequest =
          ({
            required topic,
            required chainId,
            required request,
            publication,
            requestId,
          }) async {
            publication!.throwIfCancelled();
            fail('Cancelled work reached the transport');
          };
      final notifications = <ModalError>[];
      h.modal.onModalError.subscribe((event) => notifications.add(event));
      await expectLater(
        h.modal.request(
          topic: 'original',
          chainId: 'eip155:1',
          request: params,
          publication: publication,
        ),
        throwsA(isA<RequestPublicationCancelled>()),
      );
      expect(h.uriService.launches, isEmpty);
      expect(notifications, isEmpty);
      await dispose(tester);
    },
  );

  testWidgets('ACK during disposal cannot launch the wallet', (tester) async {
    await setUpModal(tester);
    final publication = RequestPublicationController();
    final response = Completer<dynamic>();
    h.appKit.onRequest =
        ({
          required topic,
          required chainId,
          required request,
          publication,
          requestId,
        }) => response.future;
    final result = h.modal.request(
      topic: 'original',
      chainId: 'eip155:1',
      request: params,
      publication: publication,
    );
    publication.beginSend();
    final disposing = h.modal.dispose();
    publication.acknowledge();
    await tester.pump();
    expect(h.uriService.launches, isEmpty);
    response.complete('original-result');
    expect(await result, 'original-result');
    await tester.pump(const Duration(milliseconds: 600));
    await disposing;
  });

  testWidgets(
    'failed wallet launch preserves request result and UI notification',
    (tester) async {
      await setUpModal(tester);
      final publication = RequestPublicationController();
      final response = Completer<dynamic>();
      h.appKit.onRequest =
          ({
            required topic,
            required chainId,
            required request,
            publication,
            requestId,
          }) => response.future;
      h.uriService.launchError = StateError('Cannot open wallet');
      final notifications = <ModalError>[];
      h.modal.onModalError.subscribe((event) => notifications.add(event));
      final result = h.modal.request(
        topic: 'original',
        chainId: 'eip155:1',
        request: params,
        publication: publication,
      );
      publication.beginSend();
      publication.acknowledge();
      await tester.pump();
      expect(notifications.single, isA<ErrorOpeningWallet>());
      response.complete('original-result');
      expect(await result, 'original-result');
      await dispose(tester);
    },
  );
}
