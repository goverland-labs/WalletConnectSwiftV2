import Foundation
import Combine
import WalletConnectUtils
import WalletConnectPairing

class AuthClient {
    enum Errors: Error {
        case malformedPairingURI
        case unknownWalletAddress
        case noPairingMatchingTopic
    }
    private var authRequestPublisherSubject = PassthroughSubject<(id: RPCID, message: String), Never>()
    public var authRequestPublisher: AnyPublisher<(id: RPCID, message: String), Never> {
        authRequestPublisherSubject.eraseToAnyPublisher()
    }

    private var authResponsePublisherSubject = PassthroughSubject<(id: RPCID, cacao: Cacao), Never>()
    public var authResponsePublisher: AnyPublisher<(id: RPCID, cacao: Cacao), Never> {
        authResponsePublisherSubject.eraseToAnyPublisher()
    }

    private let appPairService: AppPairService
    private let appRequestService: AppRequestService
    private let appRespondSubscriber: AppRespondSubscriber

    private let walletPairService: WalletPairService
    private let walletRequestSubscriber: WalletRequestSubscriber
    private let walletRespondService: WalletRespondService
    private let cleanupService: CleanupService
    private let pairingStorage: WCPairingStorage
    private let pendingRequestsProvider: PendingRequestsProvider
    public let logger: ConsoleLogging

    private var account: Account?

    init(appPairService: AppPairService,
         appRequestService: AppRequestService,
         appRespondSubscriber: AppRespondSubscriber,
         walletPairService: WalletPairService,
         walletRequestSubscriber: WalletRequestSubscriber,
         walletRespondService: WalletRespondService,
         account: Account?,
         pendingRequestsProvider: PendingRequestsProvider,
         cleanupService: CleanupService,
         logger: ConsoleLogging,
         pairingStorage: WCPairingStorage) {
        self.appPairService = appPairService
        self.appRequestService = appRequestService
        self.walletPairService = walletPairService
        self.walletRequestSubscriber = walletRequestSubscriber
        self.walletRespondService = walletRespondService
        self.appRespondSubscriber = appRespondSubscriber
        self.account = account
        self.pendingRequestsProvider = pendingRequestsProvider
        self.cleanupService = cleanupService
        self.logger = logger
        self.pairingStorage = pairingStorage

        setUpPublishers()
    }

    public func pair(uri: String) async throws {
        guard let pairingURI = WalletConnectURI(string: uri) else {
            throw Errors.malformedPairingURI
        }
        try await walletPairService.pair(pairingURI)
    }

    public func request(_ params: RequestParams) async throws -> String {
        logger.debug("Requesting Authentication")
        let uri = try await appPairService.create()
        try await appRequestService.request(params: params, topic: uri.topic)
        return uri.absoluteString
    }

    public func request(_ params: RequestParams, topic: String) async throws {
        logger.debug("Requesting Authentication on existing pairing")
        guard pairingStorage.hasPairing(forTopic: topic) else {
            throw Errors.noPairingMatchingTopic
        }
        try await appRequestService.request(params: params, topic: topic)
    }

    public func respond(_ params: RespondParams) async throws {
        guard let account = account else { throw Errors.unknownWalletAddress }
        try await walletRespondService.respond(respondParams: params, account: account)
    }

    public func getPendingRequests() throws -> [AuthRequest] {
        guard let account = account else { throw Errors.unknownWalletAddress }
        return try pendingRequestsProvider.getPendingRequests(account: account)
    }

#if DEBUG
    /// Delete all stored data sach as: pairings, sessions, keys
    ///
    /// - Note: Doesn't unsubscribe from topics
    public func cleanup() throws {
        try cleanupService.cleanup()
    }
#endif

    private func setUpPublishers() {
        appRespondSubscriber.onResponse = { [unowned self] (id, cacao) in
            authResponsePublisherSubject.send((id, cacao))
        }

        walletRequestSubscriber.onRequest = { [unowned self] (id, message) in
            authRequestPublisherSubject.send((id, message))
        }
    }
}
