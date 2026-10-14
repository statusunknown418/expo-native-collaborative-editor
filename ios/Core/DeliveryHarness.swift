import Combine
import Foundation

/// Test-only, in-process stand-in for a server that relays one document's operations among replicas,
/// with seeded faults: every message is delayed, so messages reorder, and may be duplicated or
/// dropped. Dropped messages are redelivered once nothing else is in flight. The server accepts each
/// replica's operations in commit order, so every feed is causally ordered. A conformance tool for
/// the session's delivery hooks; not a sync adapter and not evidence of production durability.
@MainActor
final class DeliveryHarness {
  struct Faults {
    /// Ticks a message spends in flight, chosen uniformly.
    var delay: ClosedRange<Int>
    var duplicateProbability: Double
    var dropProbability: Double

    static let none = Faults(delay: 1...1, duplicateProbability: 0, dropProbability: 0)
    static let unreliable = Faults(delay: 1...6, duplicateProbability: 0.2, dropProbability: 0.2)
  }

  private enum Message {
    /// A replica's committed operation, by its index in commit order, on its way to the server.
    case upload(from: Int, index: Int)
    /// The server's acknowledgement of an operation, on its way back to the replica that sent it.
    case receipt(to: Int, UUID)
    /// An update at a position in a replica's delivery feed.
    case delivery(to: Int, position: Int, Data)
  }

  private let faults: Faults
  private var random: SeededGenerator
  private var replicas: [DocumentSession] = []
  /// Per replica: the operations it committed, in order, and how many of them the server has
  /// accepted. The server holds an operation that arrives early until those before it arrive.
  private var uploads: [[OutboxOperation]] = []
  private var accepted: [Int] = []
  private var earlyUploads: [Set<Int>] = []
  /// Per replica: every other replica's operations, in the order the server accepted them. A feed
  /// continues from the position its replica had persisted when it connected.
  private var feeds: [[Data]] = []
  private var feedStarts: [Int] = []
  private var inFlight: [(due: Int, message: Message)] = []
  private var dropped: [Message] = []
  private var now = 0
  private var subscriptions: [AnyCancellable] = []

  init(seed: UInt64, faults: Faults) {
    self.faults = faults
    random = SeededGenerator(seed: seed)
  }

  var isIdle: Bool { inFlight.isEmpty && dropped.isEmpty }

  /// Connects a replica: its pending operations upload now, later ones as they commit, and it
  /// receives operations the server accepts from now on.
  func connect(_ session: DocumentSession) throws {
    let index = replicas.count
    replicas.append(session)
    uploads.append([])
    accepted.append(0)
    earlyUploads.append([])
    feeds.append([])
    feedStarts.append(session.deliveredThrough)
    subscriptions.append(session.committedOperations.sink { [unowned self] in upload($0, from: index) })
    for operation in try session.pendingOperations() { upload(operation, from: index) }
  }

  /// Advances the clock by one tick and handles every message due by then. Once nothing is in
  /// flight, dropped messages are sent again.
  func tick() throws {
    now += 1
    let due = inFlight.filter { $0.due <= now }.map(\.message)
    inFlight.removeAll { $0.due <= now }
    for message in due { try handle(message) }
    if inFlight.isEmpty {
      let redelivering = dropped
      dropped = []
      redelivering.forEach(send)
    }
  }

  func runUntilIdle() throws {
    while !isIdle { try tick() }
  }

  /// Sends every replica its whole feed again.
  func redeliverEverything() {
    for (to, feed) in feeds.enumerated() {
      for (index, update) in feed.enumerated() {
        send(.delivery(to: to, position: feedStarts[to] + index + 1, update))
      }
    }
  }

  /// An operation that committed before its replica connected can arrive both ways; it uploads once.
  private func upload(_ operation: OutboxOperation, from replica: Int) {
    guard !uploads[replica].contains(operation) else { return }
    uploads[replica].append(operation)
    send(.upload(from: replica, index: uploads[replica].count - 1))
  }

  private func send(_ message: Message) {
    if Double.random(in: 0..<1, using: &random) < faults.dropProbability {
      dropped.append(message)
      return
    }
    inFlight.append((now + Int.random(in: faults.delay, using: &random), message))
    if Double.random(in: 0..<1, using: &random) < faults.duplicateProbability {
      inFlight.append((now + Int.random(in: faults.delay, using: &random), message))
    }
  }

  private func handle(_ message: Message) throws {
    switch message {
    case .upload(let from, let index):
      guard index >= accepted[from] else {
        // Already accepted: the receipt goes out again, since the first one may have been lost.
        return send(.receipt(to: from, uploads[from][index].operationID))
      }
      earlyUploads[from].insert(index)
      while earlyUploads[from].remove(accepted[from]) != nil {
        let operation = uploads[from][accepted[from]]
        accepted[from] += 1
        for to in replicas.indices where to != from {
          feeds[to].append(operation.update)
          send(.delivery(to: to, position: feedStarts[to] + feeds[to].count, operation.update))
        }
        send(.receipt(to: from, operation.operationID))
      }
    case .receipt(let to, let operationID):
      try replicas[to].acknowledge([operationID])
    case .delivery(let to, let position, let update):
      try replicas[to].receive(update, at: position)
    }
  }
}

/// SplitMix64: every value follows from the seed, so a seed reproduces a run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
