/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
@testable import LiveKit
import Testing

/// The data delegate carries the SFU-stamped sender identity even when the sender is not (yet) in
/// the participant roster: signal-channel participant updates and data-channel packets are unordered.
struct UserPacketSenderIdentityTests {
    struct Delivery: Sendable, Equatable {
        let senderIdentity: String?
        let hasParticipant: Bool
        let topic: String
        let data: Data
    }

    final class Recorder: NSObject, RoomDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var stamped: [Delivery] = []
        private var legacyCount = 0

        func room(_: Room, senderIdentity: Participant.Identity?, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
            lock.withLock { stamped.append(Delivery(senderIdentity: senderIdentity?.stringValue, hasParticipant: participant != nil, topic: topic, data: data)) }
        }

        func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic _: String, encryptionType _: EncryptionType) {
            lock.withLock { legacyCount += 1 }
        }

        var snapshot: (stamped: [Delivery], legacyCount: Int) { lock.withLock { (stamped, legacyCount) } }
    }

    private func connectedRoom(with recorder: Recorder) -> Room {
        let room = Room()
        room.add(delegate: recorder)
        room._state.mutate { $0.connectionState = .connected }
        return room
    }

    private func packet(from identity: String, topic: String, payload: Data) -> Livekit_UserPacket {
        Livekit_UserPacket.with {
            $0.participantIdentity = identity
            $0.topic = topic
            $0.payload = payload
        }
    }

    /// Delivers a user packet the way `Room.dataChannel(_:didReceiveDataPacket:)` does: the outer
    /// `DataPacket.participant_identity` is the SFU-stamped one.
    private func deliver(_ userPacket: Livekit_UserPacket, stamped: String, encryptionType: EncryptionType = .none, to room: Room) {
        let dataPacket = Livekit_DataPacket.with {
            $0.participantIdentity = stamped
            $0.user = userPacket
        }
        room.dataChannel(room.publisherDataChannel, didReceiveDataPacket: dataPacket, encryptionType: encryptionType)
    }

    private func waitForDeliveries(_ recorder: Recorder, count: Int) async throws -> (stamped: [Delivery], legacyCount: Int) {
        for _ in 0 ..< 200 {
            let snapshot = recorder.snapshot
            if snapshot.stamped.count >= count, snapshot.legacyCount >= count { return snapshot }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return recorder.snapshot
    }

    @Test func senderNotInRosterStillCarriesItsStampedIdentity() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)
        let payload = Data([1, 2, 3])

        deliver(packet(from: "game-server", topic: "conductor", payload: payload), stamped: "game-server", to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped == [Delivery(senderIdentity: "game-server", hasParticipant: false, topic: "conductor", data: payload)])
        // The existing delegate method is still called, unchanged.
        #expect(snapshot.legacyCount == 1)
    }

    @Test func senderInRosterCarriesIdentityAndParticipant() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)
        let info = Livekit_ParticipantInfo.with {
            $0.identity = "game-server"
            $0.sid = "PA_server"
        }
        let remote = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "game-server")] = remote }

        deliver(packet(from: "game-server", topic: "conductor", payload: Data([9])), stamped: "game-server", to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped.first?.senderIdentity == "game-server")
        #expect(snapshot.stamped.first?.hasParticipant == true)
    }

    @Test func packetWithoutIdentityHasNoSender() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)

        deliver(packet(from: "", topic: "conductor", payload: Data([7])), stamped: "", to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped.first?.senderIdentity == nil)
        #expect(snapshot.stamped.first?.hasParticipant == false)
    }

    /// The outer, SFU-stamped identity wins over the sender-controlled inner one.
    @Test func stampedOuterIdentityWinsOverTheInnerOne() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)

        deliver(packet(from: "game-server", topic: "conductor", payload: Data([5])), stamped: "player-2", to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped.first?.senderIdentity == "player-2")
    }

    /// With E2EE the inner identity is inside the ciphertext, written by the sender: never trusted.
    @Test func encryptedPacketNeverFallsBackToTheInnerIdentity() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)

        deliver(packet(from: "game-server", topic: "conductor", payload: Data([6])), stamped: "", encryptionType: .gcm, to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped.first?.senderIdentity == nil)
    }

    /// An unencrypted packet from an older server that leaves the outer field empty falls back to the
    /// inner identity, which the SFU also overwrites in plaintext.
    @Test func unencryptedPacketWithoutOuterIdentityUsesTheInnerOne() async throws {
        let recorder = Recorder()
        let room = connectedRoom(with: recorder)

        deliver(packet(from: "game-server", topic: "conductor", payload: Data([8])), stamped: "", to: room)

        let snapshot = try await waitForDeliveries(recorder, count: 1)
        #expect(snapshot.stamped.first?.senderIdentity == "game-server")
    }
}
