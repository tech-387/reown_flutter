import 'package:event/event.dart';
import 'package:reown_core/reown_core.dart';
import 'package:reown_core/store/i_generic_store.dart';
import 'package:reown_sign/store/i_sessions.dart';
import 'package:reown_sign/models/basic_models.dart';
import 'package:reown_sign/models/proposal_models.dart';
import 'package:reown_sign/models/session_models.dart';
import 'package:reown_sign/models/sign_client_events.dart';
import 'package:reown_sign/models/cacao_models.dart';

abstract class IReownSignCommon {
  abstract final Event<SessionConnect> onSessionConnect;
  abstract final Event<SessionDelete> onSessionDelete;
  abstract final Event<SessionExpire> onSessionExpire;
  abstract final Event<SessionPing> onSessionPing;
  abstract final Event<SessionProposalEvent> onProposalExpire;

  abstract final IReownCore core;
  abstract final PairingMetadata metadata;
  abstract final IGenericStore<ProposalData> proposals;
  abstract final ISessions sessions;
  abstract final IGenericStore<SessionRequest> pendingRequests;

  abstract final IGenericStore<AuthPublicKey> authKeys;
  abstract final IPairingStore pairings;
  abstract final IGenericStore<String> pairingTopics;

  Future<void> init();

  /// Revokes local session use even when peer notification fails or is offline.
  /// Completion does not imply peer acknowledgement. Existing response waiters
  /// retain their keys/subscriptions until settlement; local cleanup errors throw.
  /// Failed cleanup remains revoked and can be retried with the same topic.
  Future<void> disconnectSession({
    required String topic,
    required ReownSignError reason,
  });
  Map<String, SessionData> getActiveSessions();
  Map<String, SessionData> getSessionsForPairing({
    required String pairingTopic,
  });
  Map<String, ProposalData> getPendingSessionProposals();

  String formatAuthMessage({
    required String iss,
    required CacaoRequestPayload cacaoPayload,
  });

  Future<bool> validateSignedCacao({
    required Cacao cacao,
    required String projectId,
  });

  Future<void> dispatchEnvelope(String url);
}
