import Foundation
import Testing
import ClientKit
import ContractKit
@testable import ClientModel

// MARK: - Settings

@Suite("SessionModel settings")
@MainActor
struct SessionModelSettingsTests {
    @Test("loads the persisted host, port and token")
    func loadsPersistedSettings() {
        let stored = PhotonConnectionSettings(host: "10.0.0.2", port: "9000", token: "abc")
        let session = SessionModel(
            settingsStore: InMemorySettingsStore(stored),
            makeClient: { _ in FakePhotonClient() }
        )

        #expect(session.host == "10.0.0.2")
        #expect(session.port == "9000")
        #expect(session.token == "abc")
        #expect(session.isConfigured)
    }

    @Test("an empty store keeps the M3 defaults")
    func emptyStoreDefaults() {
        let session = SessionModel(
            settingsStore: InMemorySettingsStore(),
            makeClient: { _ in FakePhotonClient() }
        )

        #expect(session.host.isEmpty)
        #expect(session.port == SessionModel.defaultPort)
        #expect(session.port == "8787")
        #expect(session.token.isEmpty)
        #expect(!session.isConfigured)
        #expect(session.phase == .unconfigured)
        #expect(session.client == nil)
    }

    @Test("editing a setting persists all three")
    func persistsEdits() {
        let store = InMemorySettingsStore()
        let session = SessionModel(settingsStore: store, makeClient: { _ in FakePhotonClient() })

        session.host = "192.168.1.9"
        session.port = "9000"
        session.token = "token"

        let saved = store.current
        #expect(saved == PhotonConnectionSettings(host: "192.168.1.9", port: "9000", token: "token"))
    }

    @Test("isConfigured trims and validates the port")
    func isConfiguredRules() {
        let session = SessionModel(
            settingsStore: InMemorySettingsStore(),
            makeClient: { _ in FakePhotonClient() }
        )

        session.host = " 192.168.1.5 "
        session.token = " secret "
        session.port = " 8787 "
        #expect(session.isConfigured)

        session.port = "0"
        #expect(!session.isConfigured)
        session.port = "65536"
        #expect(!session.isConfigured)
        session.port = "http"
        #expect(!session.isConfigured)
        session.port = "8787"
        #expect(session.isConfigured)

        session.host = "   "
        #expect(!session.isConfigured)
        session.host = "192.168.1.5"
        session.token = "\n"
        #expect(!session.isConfigured)
    }

    @Test("connect refuses invalid settings without touching the transport")
    func connectRejectsInvalidSettings() async throws {
        let harness = try Harness()
        let session = harness.session
        let client = harness.client

        session.host = "   "
        await session.connect()
        #expect(session.phase == .unconfigured)
        #expect(session.notice?.message == "Enter the Mac's LAN address first.")
        #expect(session.notice?.severity == .warning)
        #expect(session.notice?.canRetry == false)

        session.host = "192.168.1.5"
        session.port = "70000"
        await session.connect()
        #expect(session.phase == .unconfigured)
        #expect(session.notice?.message == "The port must be a number between 1 and 65535.")

        session.port = "8787"
        session.token = "  "
        await session.connect()
        #expect(session.phase == .unconfigured)
        #expect(session.notice?.message == "Enter the bearer token printed by `appctl serve`.")

        #expect(client.calls().isEmpty)
        #expect(session.client == nil)
    }

    @Test("start is a no-op without saved settings")
    func startNeedsSettings() async {
        let client = FakePhotonClient()
        let session = SessionModel(settingsStore: InMemorySettingsStore(), makeClient: { _ in client })

        await session.start()

        #expect(session.phase == .unconfigured)
        #expect(session.client == nil)
        #expect(client.calls().isEmpty)
    }
}

// MARK: - Connection

@Suite("SessionModel connection")
@MainActor
struct SessionModelConnectionTests {
    @Test("connect probes health, lists the batch, and stores the client")
    func connectSuccess() async throws {
        let harness = try Harness()
        await harness.connect()

        #expect(harness.session.phase == .connected)
        #expect(harness.session.isConnected)
        #expect(harness.session.client != nil)
        #expect(harness.session.health?.itemCount == 2)
        #expect(harness.session.items.map(\.id) == [Fixtures.idA, Fixtures.idB])
        #expect(!harness.session.isRefreshing)
        #expect(harness.session.notice == nil)
        #expect(harness.client.calls() == [.health, .listItems])
    }

    @Test("start auto-connects with saved settings")
    func startAutoConnects() async throws {
        let harness = try Harness()
        await harness.session.start()

        #expect(harness.session.phase == .connected)
        #expect(harness.session.isConnected)
    }

    @Test("a failed health probe returns to error with a retryable notice")
    func connectFailure() async throws {
        let harness = try Harness()
        harness.client.healthHandler = { throw ClientError.network(message: "unreachable") }

        await harness.connect()

        #expect(!harness.session.isConnected)
        #expect(harness.session.phase == .error)
        #expect(harness.session.client == nil)
        #expect(harness.session.health == nil)
        #expect(harness.session.notice?.severity == .error)
        #expect(harness.session.notice?.canRetry == true)
        #expect(harness.session.notice?.message == ClientError.network(message: "unreachable").userMessage)
    }

    @Test("retry repeats a failed connect after the Mac comes back")
    func retryConnect() async throws {
        let harness = try Harness()
        harness.client.healthHandler = { throw ClientError.network(message: "unreachable") }
        await harness.connect()
        #expect(harness.session.phase == .error)

        harness.client.healthHandler = { Fixtures.health(itemCount: 2) }
        await harness.session.retry()

        #expect(harness.session.phase == .connected)
        #expect(harness.session.notice == nil)
        #expect(harness.session.health?.itemCount == 2)
    }

    @Test("401 on health returns to unconfigured and drops the client")
    func unauthorizedHealth() async throws {
        let harness = try Harness()
        harness.client.healthHandler = { throw ClientError.unauthorized }

        await harness.connect()

        #expect(harness.session.phase == .unconfigured)
        #expect(harness.session.client == nil)
        #expect(harness.session.health == nil)
        #expect(harness.session.items.isEmpty)
        #expect(harness.session.notice?.severity == .error)
        #expect(harness.session.notice?.canDismiss == true)
        #expect(harness.session.notice?.canRetry == false)
        #expect(harness.session.notice?.message == ClientError.unauthorized.userMessage)
    }

    @Test("an invalid configuration from the factory returns to unconfigured")
    func invalidConfiguration() async throws {
        let store = InMemorySettingsStore(.test)
        let session = SessionModel(settingsStore: store) { _ in
            throw ClientError.invalidConfiguration(message: "the host is empty")
        }

        await session.connect()

        #expect(session.phase == .unconfigured)
        #expect(session.client == nil)
        #expect(session.notice?.severity == .error)
        #expect(session.notice?.message == "invalid connection settings: the host is empty")
        #expect(session.notice?.canRetry == false)
    }

    @Test("disconnect clears the client, batch and settings phase")
    func disconnect() async throws {
        let harness = try Harness()
        await harness.connect()

        harness.session.disconnect()

        #expect(harness.session.phase == .unconfigured)
        #expect(harness.session.client == nil)
        #expect(harness.session.health == nil)
        #expect(harness.session.items.isEmpty)
        #expect(!harness.session.isConnected)
        #expect(harness.session.notice == nil)
    }

    @Test("connect is ignored while a base load is in flight")
    func connectBlockedWhileLoading() async throws {
        let harness = try Harness()
        await harness.connect()
        let gate = Gate()
        let png = harness.png
        harness.client.previewHandler = { _, _ in
            await gate.wait()
            return png
        }

        let load = Task { await harness.judge.select(itemID: Fixtures.idA) }
        await waitUntil("load in flight") { harness.judge.phase == .loading }

        let healthCalls = harness.client.callCount(.health)
        await harness.session.connect()
        #expect(harness.client.callCount(.health) == healthCalls)
        #expect(harness.session.phase == .connected)

        await gate.open()
        await load.value
        #expect(harness.judge.phase == .judging)
    }
}


// MARK: - Refresh

@Suite("SessionModel refresh")
@MainActor
struct SessionModelRefreshTests {
    @Test("a refresh reconciles the judge's selection and cached review")
    func refreshKeepsSelection() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        #expect(harness.judge.phase == .judging)

        let renamed = Fixtures.item(id: Fixtures.idA, name: "renamed.tif", path: Fixtures.pathA)
        harness.client.listHandler = { [renamed, Fixtures.itemB] }

        let refreshed = await harness.session.refreshItems()

        #expect(refreshed)
        #expect(harness.session.items.first?.name == "renamed.tif")
        #expect(harness.judge.selectedItemID == Fixtures.idA)
        #expect(harness.judge.selectedItem?.name == "renamed.tif")
        #expect(harness.judge.review?.item.name == "renamed.tif")
        #expect(harness.judge.phase == .judging)
    }

    @Test("an item that left the batch clears the selection and returns to idle")
    func refreshDropsSelection() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        harness.judge.setStart(0.4)

        harness.client.listHandler = { [Fixtures.itemB] }
        await harness.session.refreshItems()

        #expect(harness.session.items.map(\.id) == [Fixtures.idB])
        #expect(harness.judge.selectedItemID == nil)
        #expect(harness.judge.selectedItem == nil)
        #expect(harness.judge.review == nil)
        #expect(harness.judge.phase == .idle)
        #expect(harness.session.phase == .connected)
    }

    @Test("a failed refresh keeps the base on screen and is retried from the judge")
    func refreshFailureKeepsReview() async throws {
        let harness = try Harness()
        await harness.connect()
        await harness.judge.select(itemID: Fixtures.idA)
        harness.judge.setStart(0.4)

        harness.client.listHandler = { throw ClientError.network(message: "dropped") }
        let refreshed = await harness.session.refreshItems()

        #expect(!refreshed)
        #expect(harness.session.phase == .error)
        #expect(harness.session.notice?.severity == .error)
        #expect(harness.session.notice?.canRetry == true)
        #expect(harness.judge.phase == .judging)
        #expect(harness.judge.review?.item.id == Fixtures.idA)
        #expect(harness.judge.draft?.start == 0.4)
        #expect(harness.judge.activeNotice == harness.session.notice)

        harness.client.listHandler = { [Fixtures.itemA, Fixtures.itemB] }
        await harness.judge.retry()

        #expect(harness.session.phase == .connected)
        #expect(harness.session.notice == nil)
        #expect(harness.judge.phase == .judging)
        #expect(harness.judge.review?.item.id == Fixtures.idA)
    }

    @Test("refresh without a client stays unconfigured")
    func refreshWithoutClient() async {
        let session = SessionModel(
            settingsStore: InMemorySettingsStore(),
            makeClient: { _ in FakePhotonClient() }
        )

        let refreshed = await session.refreshItems()

        #expect(!refreshed)
        #expect(session.phase == .unconfigured)
        #expect(session.items.isEmpty)
        #expect(!session.isRefreshing)
    }
}
