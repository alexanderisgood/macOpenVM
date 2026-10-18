// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import VMCore

private func serialBytes(_ value: String) -> Data { Data(value.utf8) }

private func guestPayload(_ events: [SerialControlEvent]) -> Data {
  events.reduce(into: Data()) { result, event in
    if case .guestBytes(let bytes) = event { result.append(bytes) }
  }
}

private func hostEvents(_ events: [SerialControlEvent]) -> [SerialControlEvent] {
  events.filter {
    if case .guestBytes = $0 { return false }
    return true
  }
}

private func drainSerialInput(
  _ input: Data, parser: inout SerialControlParser, now: UInt64 = 0
) -> [SerialControlEvent] {
  var consumed = 0
  var events: [SerialControlEvent] = []
  while consumed < input.count {
    let batch = parser.consume(input.dropFirst(consumed), nowMilliseconds: now)
    #expect(batch.consumedBytes > 0)
    #expect(batch.consumedBytes <= SerialControlParser.maximumInputBytes)
    #expect(batch.consumedBytes <= input.count - consumed)
    #expect(batch.events.count <= SerialControlParser.maximumEvents)
    guard batch.consumedBytes > 0 else { break }
    consumed += batch.consumedBytes
    events.append(contentsOf: batch.events)
  }
  #expect(consumed == input.count)
  return events
}

private func openForceBarrier(
  _ parser: inout SerialControlParser, now: UInt64 = 0
) throws -> UInt64 {
  let batch = parser.consume(Data([0x1D, 0x66]), nowMilliseconds: now)
  #expect(batch.consumedBytes == 2)
  #expect(batch.events.first == .menuOpened)
  let id = try #require(
    batch.events.compactMap { event -> UInt64? in
      if case .forceConfirmationNeeded(let id) = event { return id }
      return nil
    }.first)
  #expect(parser.phase == .awaitingInputBarrier)
  return id
}

private func armForceConfirmation(
  _ parser: inout SerialControlParser, now: UInt64 = 0
) throws -> UInt64 {
  let id = try openForceBarrier(&parser, now: now)
  #expect(
    parser.completeInputBarrier(for: id, nowMilliseconds: now) == [.forceConfirmationArmed(id)])
  #expect(parser.phase == .awaitingConfirmation)
  return id
}

@Test func serialOrdinaryBytesIncludingControlCPassUnchangedInBoundedBatches() {
  // Every byte value except the documented host escape is ordinary guest input.
  let pattern = (UInt8.min...UInt8.max).filter { $0 != 0x1D }
  let input = Data((0..<4200).flatMap { _ in pattern })
  var parser = SerialControlParser()
  let first = parser.consume(input, nowMilliseconds: 0)
  #expect(first.consumedBytes == 4096)
  #expect(first.events.count == 1)
  #expect(guestPayload(first.events) == input.prefix(4096))
  var events = first.events
  events.append(contentsOf: drainSerialInput(input.dropFirst(first.consumedBytes), parser: &parser))
  #expect(guestPayload(events) == input)
  #expect(hostEvents(events).isEmpty)
  #expect(parser.phase == .guest)
  #expect(parser.consume(Data(), nowMilliseconds: 0).consumedBytes == 0)
}

@Test func serialEscapeAndMenuOperationsSurviveEveryChunkBoundary() {
  let input =
    serialBytes("before") + Data([0x03, 0x1D, 0x1D]) + serialBytes("after\n")
    + Data([0x1D]) + serialBytes("prs?c")
  let expectedGuest = serialBytes("before") + Data([0x03, 0x1D]) + serialBytes("after\n")
  let expectedHost: [SerialControlEvent] = [
    .menuOpened, .menuClosed, .menuOpened, .request(.pause), .request(.resume),
    .request(.requestShutdown), .menuOpened, .menuClosed,
  ]
  for boundary in 0...input.count {
    var parser = SerialControlParser()
    let first = parser.consume(input.prefix(boundary), nowMilliseconds: 0)
    let second = parser.consume(input.dropFirst(boundary), nowMilliseconds: 0)
    #expect(first.consumedBytes == boundary)
    #expect(second.consumedBytes == input.count - boundary)
    let events = first.events + second.events
    #expect(guestPayload(events) == expectedGuest)
    #expect(hostEvents(events) == expectedHost)
    #expect(parser.phase == .guest)
  }
}

@Test func serialEventFloodRetainsEveryUnconsumedCommandAndDoubledEscape() {
  var parser = SerialControlParser()
  let commands = Data([0x1D]) + Data(repeating: 0x70, count: 10_000)
  let commandEvents = drainSerialInput(commands, parser: &parser)
  #expect(commandEvents.filter { $0 == .request(.pause) }.count == 10_000)
  #expect(commandEvents.filter { $0 == .menuOpened }.count == 1)
  #expect(parser.phase == .menu)
  #expect(parser.cancelHostControl() == [.menuClosed])

  let doubledEscapes = Data((0..<5000).flatMap { _ in [UInt8(0x1D), UInt8(0x1D)] })
  let escapeEvents = drainSerialInput(doubledEscapes, parser: &parser)
  #expect(guestPayload(escapeEvents) == Data(repeating: 0x1D, count: 5000))
  #expect(escapeEvents.filter { $0 == .menuOpened }.count == 5000)
  #expect(escapeEvents.filter { $0 == .menuClosed }.count == 5000)
  #expect(parser.phase == .guest)
}

@Test func serialUnknownMenuInputIsConsumedWithoutGuestForwardingOrLifecycleRequests() {
  var parser = SerialControlParser()
  let input = Data([0x1D, 0x00, 0xFF, 0x78, 0x0A, 0x0D])
  let unknown = parser.consume(input, nowMilliseconds: 0)
  #expect(unknown.consumedBytes == input.count)
  #expect(unknown.events == [.menuOpened] + Array(repeating: .unknownMenuCommand, count: 3))
  #expect(parser.phase == .menu)
  let close = parser.consume(serialBytes("cdiscarded-prompt-paste"), nowMilliseconds: 1)
  #expect(close.events == [.menuClosed])
  #expect(parser.phase == .guest)
  #expect(
    guestPayload(parser.consume(serialBytes("fresh"), nowMilliseconds: 2).events)
      == serialBytes("fresh"))
}

@Test func serialBufferedPasteCannotArmOrConfirmHostForceStop() throws {
  var parser = SerialControlParser()
  let input =
    Data([0x1D]) + serialBytes("fFORCE STOP\n")
    + Data(repeating: 0x66, count: 8192) + serialBytes("FORCE STOP\n")
  let events = drainSerialInput(input, parser: &parser)
  let id = try #require(
    events.compactMap { event -> UInt64? in
      if case .forceConfirmationNeeded(let id) = event { return id }
      return nil
    }.first)
  #expect(events == [.menuOpened, .forceConfirmationNeeded(id)])
  #expect(parser.phase == .awaitingInputBarrier)
  #expect(guestPayload(events).isEmpty)
  #expect(parser.completeInputBarrier(for: id, nowMilliseconds: 1) == [.forceConfirmationArmed(id)])
  let fresh = parser.consume(serialBytes("FORCE STOP\n"), nowMilliseconds: 2)
  #expect(fresh.events == [.request(.forceStop(confirmationID: id)), .menuClosed])
  #expect(parser.phase == .guest)
}

@Test func serialForceTokenMustBeExactAcrossEveryChunkBoundary() throws {
  let token = serialBytes("FORCE STOP\n")
  for boundary in 0...token.count {
    var parser = SerialControlParser()
    let id = try armForceConfirmation(&parser, now: 100)
    let first = parser.consume(token.prefix(boundary), nowMilliseconds: 101)
    let second = parser.consume(token.dropFirst(boundary), nowMilliseconds: 102)
    #expect(first.consumedBytes == boundary)
    #expect(second.consumedBytes == token.count - boundary)
    #expect(
      first.events + second.events == [.request(.forceStop(confirmationID: id)), .menuClosed])
    #expect(parser.phase == .guest)
  }
}

@Test(arguments: ["force stop", "FORCESTOP", " FORCE STOP", "FORCE STOP ", "FORCE STOPX", ""])
func serialInvalidForceTokensAreRejectedWithoutGuestForwarding(token: String) throws {
  var parser = SerialControlParser()
  _ = try armForceConfirmation(&parser)
  let batch = parser.consume(serialBytes(token + "\nFORCE STOP\n"), nowMilliseconds: 1)
  #expect(batch.events == [.confirmationRejected])
  #expect(batch.consumedBytes == token.utf8.count + 12)
  #expect(parser.phase == .menu)
  #expect(guestPayload(batch.events).isEmpty)
}

@Test func serialConfirmationLimitsASCIIAndDiscardsInvalidLineThroughNewline() throws {
  var parser = SerialControlParser()
  _ = try armForceConfirmation(&parser)
  let atLimit = parser.consume(Data(repeating: 0x41, count: 32), nowMilliseconds: 1)
  #expect(atLimit.events.isEmpty)
  #expect(parser.phase == .awaitingConfirmation)
  let overLimit = parser.consume(Data([0x41]), nowMilliseconds: 2)
  #expect(overLimit.events == [.confirmationRejected])
  #expect(parser.phase == .discardingConfirmation)
  let discard = parser.consume(serialBytes("FORCE STOP\nfFORCE STOP\n"), nowMilliseconds: 3)
  #expect(discard.events.isEmpty)
  #expect(parser.phase == .menu)
  #expect(guestPayload(discard.events).isEmpty)

  for invalid: UInt8 in [0x00, 0x09, 0x1F, 0x7F, 0x80, 0xFF] {
    var invalidParser = SerialControlParser()
    _ = try armForceConfirmation(&invalidParser)
    let batch = invalidParser.consume(
      serialBytes("FORCE ") + Data([invalid]) + serialBytes("STOP"), nowMilliseconds: 1)
    #expect(batch.events == [.confirmationRejected])
    #expect(invalidParser.phase == .discardingConfirmation)
    #expect(invalidParser.consume(serialBytes("FORCE STOP"), nowMilliseconds: 2).events.isEmpty)
    #expect(invalidParser.phase == .discardingConfirmation)
    #expect(invalidParser.consume(Data([0x0A]), nowMilliseconds: 3).events.isEmpty)
    #expect(invalidParser.phase == .menu)
  }
}

@Test func serialCRLFConfirmationDoesNotSwallowLaterOrdinaryGuestNewlines() throws {
  for boundary in 0...2 {
    var parser = SerialControlParser()
    let id = try armForceConfirmation(&parser)
    #expect(parser.consume(serialBytes("FORCE STOP"), nowMilliseconds: 1).events.isEmpty)
    let lineEnd = Data([0x0D, 0x0A])
    let first = parser.consume(lineEnd.prefix(boundary), nowMilliseconds: 2)
    let second = parser.consume(lineEnd.dropFirst(boundary), nowMilliseconds: 3)
    #expect(
      first.events + second.events == [.request(.forceStop(confirmationID: id)), .menuClosed])
    let ordinary = parser.consume(serialBytes("\nordinary\n"), nowMilliseconds: 4)
    #expect(guestPayload(ordinary.events) == serialBytes("\nordinary\n"))
    #expect(parser.phase == .guest)
  }
}

@Test func serialSuccessfulConfirmationDiscardsRemainingPromptPaste() throws {
  var parser = SerialControlParser()
  let id = try armForceConfirmation(&parser)
  let paste = parser.consume(
    serialBytes("FORCE STOP\r\n") + Data([0x1D]) + serialBytes("fFORCE STOP\n"),
    nowMilliseconds: 1)
  #expect(paste.events == [.request(.forceStop(confirmationID: id)), .menuClosed])
  #expect(guestPayload(paste.events).isEmpty)
  #expect(parser.phase == .guest)
  #expect(
    guestPayload(parser.consume(serialBytes("\nfresh"), nowMilliseconds: 2).events)
      == serialBytes("\nfresh"))
}

@Test(arguments: [UInt8(0x03), UInt8(0x1B)])
func serialMenuAndForceCancellationNeverForwardPromptPaste(cancel: UInt8) throws {
  var menu = SerialControlParser()
  let menuBatch = menu.consume(Data([0x1D, cancel]) + serialBytes("paste"), nowMilliseconds: 0)
  #expect(menuBatch.events == [.menuOpened, .menuClosed])
  #expect(guestPayload(menuBatch.events).isEmpty)
  #expect(menu.phase == .guest)

  for armed in [false, true] {
    var parser = SerialControlParser()
    let id = try openForceBarrier(&parser)
    if armed { _ = parser.completeInputBarrier(for: id, nowMilliseconds: 0) }
    let batch = parser.consume(Data([cancel]) + serialBytes("FORCE STOP\n"), nowMilliseconds: 1)
    #expect(batch.events == [.confirmationCancelled])
    #expect(guestPayload(batch.events).isEmpty)
    #expect(parser.phase == .menu)
    #expect(parser.cancelHostControl() == [.menuClosed])
    #expect(parser.phase == .guest)
  }
}

@Test func serialEscapeCancelsConfirmationWithoutReopeningOrForwardingTheEscape() throws {
  var parser = SerialControlParser()
  _ = try armForceConfirmation(&parser)
  _ = parser.consume(serialBytes("FORCE "), nowMilliseconds: 1)
  let cancelled = parser.consume(Data([0x1D]) + serialBytes("STOP\n"), nowMilliseconds: 2)
  #expect(cancelled.events == [.confirmationCancelled])
  #expect(parser.phase == .menu)
  #expect(guestPayload(cancelled.events).isEmpty)
}

@Test func serialExplicitCancellationClosesEveryHostPromptAndPreservesIDMonotonicity() throws {
  var parser = SerialControlParser()
  #expect(parser.cancelHostControl().isEmpty)
  _ = parser.consume(Data([0x1D]), nowMilliseconds: 0)
  #expect(parser.cancelHostControl() == [.menuClosed])
  let firstID = try openForceBarrier(&parser)
  #expect(parser.cancelHostControl() == [.confirmationCancelled, .menuClosed])
  let secondID = try armForceConfirmation(&parser)
  #expect(secondID > firstID)
  #expect(parser.consume(serialBytes("FORCE "), nowMilliseconds: 1).events.isEmpty)
  #expect(parser.cancelHostControl() == [.confirmationCancelled, .menuClosed])
  let thirdID = try armForceConfirmation(&parser)
  #expect(thirdID > secondID)
  _ = parser.consume(Data([0xFF]), nowMilliseconds: 1)
  #expect(parser.phase == .discardingConfirmation)
  #expect(parser.cancelHostControl() == [.confirmationCancelled, .menuClosed])
  #expect(parser.phase == .guest)
}

@Test func serialStaleBarrierCompletionsCannotResetOrArmAnotherConfirmation() throws {
  var parser = SerialControlParser()
  let oldID = try openForceBarrier(&parser)
  _ = parser.consume(Data([0x03]), nowMilliseconds: 1)
  let newBarrier = parser.consume(Data([0x66]), nowMilliseconds: 2)
  let newID = try #require(
    newBarrier.events.compactMap { event -> UInt64? in
      if case .forceConfirmationNeeded(let id) = event { return id }
      return nil
    }.first)
  #expect(newID > oldID)
  #expect(parser.completeInputBarrier(for: oldID, nowMilliseconds: 3) == [.staleConfirmation])
  #expect(parser.phase == .awaitingInputBarrier)
  #expect(
    parser.completeInputBarrier(for: newID, nowMilliseconds: 4) == [.forceConfirmationArmed(newID)])
  _ = parser.consume(serialBytes("FORCE "), nowMilliseconds: 5)
  #expect(parser.completeInputBarrier(for: newID, nowMilliseconds: 6) == [.staleConfirmation])
  let finish = parser.consume(serialBytes("STOP\n"), nowMilliseconds: 7)
  #expect(finish.events == [.request(.forceStop(confirmationID: newID)), .menuClosed])
}

@Test func serialConfirmationDeadlineExpiresExactlyAndRegressingClockCannotExtendIt() throws {
  var parser = SerialControlParser()
  let id = try armForceConfirmation(&parser, now: 1000)
  #expect(parser.advanceTime(to: 10_999).isEmpty)
  #expect(parser.advanceTime(to: 0).isEmpty)
  #expect(parser.advanceTime(to: 11_000) == [.confirmationExpired])
  #expect(parser.phase == .discardingConfirmation)
  #expect(parser.advanceTime(to: 12_000).isEmpty)
  #expect(parser.completeInputBarrier(for: id, nowMilliseconds: 0) == [.staleConfirmation])
  let stalePaste = parser.consume(serialBytes("FORCE STOP\nfFORCE STOP\n"), nowMilliseconds: 0)
  #expect(stalePaste.events.isEmpty)
  #expect(parser.phase == .menu)

  var beforeDeadline = SerialControlParser()
  let validID = try armForceConfirmation(&beforeDeadline, now: 1000)
  let valid = beforeDeadline.consume(serialBytes("FORCE STOP\n"), nowMilliseconds: 10_999)
  #expect(valid.events == [.request(.forceStop(confirmationID: validID)), .menuClosed])
}

@Test func serialInputBarrierTimeCountsTowardTheSameTenSecondDeadline() throws {
  var parser = SerialControlParser()
  let id = try openForceBarrier(&parser, now: 0)
  #expect(
    parser.completeInputBarrier(for: id, nowMilliseconds: 10_000)
      == [.confirmationExpired, .staleConfirmation])
  #expect(parser.phase == .discardingConfirmation)
  #expect(parser.consume(serialBytes("FORCE STOP\n"), nowMilliseconds: 10_001).events.isEmpty)
  #expect(parser.phase == .menu)

  var partial = SerialControlParser()
  _ = try armForceConfirmation(&partial)
  _ = partial.consume(serialBytes("FORCE "), nowMilliseconds: 9999)
  let expired = partial.consume(serialBytes("STOP\n"), nowMilliseconds: 10_000)
  #expect(expired.events == [.confirmationExpired])
  #expect(partial.phase == .menu)
}

@Test func serialTimeAndSequenceOverflowFailClosedWithoutWrappingOrArming() throws {
  for now in [UInt64.max, UInt64.max - 9999] {
    var parser = SerialControlParser()
    let rejected = parser.consume(Data([0x1D, 0x66]), nowMilliseconds: now)
    #expect(rejected.events == [.menuOpened, .confirmationRejected])
    #expect(parser.phase == .menu)
    #expect(parser.completeInputBarrier(for: 1, nowMilliseconds: now) == [.staleConfirmation])
  }
  var lastRepresentableDeadline = SerialControlParser()
  let id = try armForceConfirmation(&lastRepresentableDeadline, now: UInt64.max - 10_000)
  let valid = lastRepresentableDeadline.consume(
    serialBytes("FORCE STOP\n"), nowMilliseconds: UInt64.max - 1)
  #expect(valid.events == [.request(.forceStop(confirmationID: id)), .menuClosed])

  var sequence = SerialControlParser(nextConfirmationID: UInt64.max - 1)
  let lastID = try openForceBarrier(&sequence)
  #expect(lastID == UInt64.max)
  _ = sequence.cancelHostControl()
  let exhausted = sequence.consume(Data([0x1D, 0x66]), nowMilliseconds: 1)
  #expect(exhausted.events == [.menuOpened, .confirmationRejected])
  #expect(sequence.phase == .menu)
  #expect(sequence.completeInputBarrier(for: 0, nowMilliseconds: 1) == [.staleConfirmation])
}

@Test func serialDescriptionsNeverDiscloseGuestOrPartialConfirmationPayload() throws {
  let sentinel = "synthetic-private-serial-sentinel-39dcf7"
  var parser = SerialControlParser()
  let guest = parser.consume(serialBytes(sentinel), nowMilliseconds: 0)
  let guestDescriptions =
    [
      String(describing: guest), String(reflecting: guest), String(describing: parser),
      String(reflecting: parser),
    ] + guest.events.flatMap { [String(describing: $0), String(reflecting: $0)] }
  #expect(guestDescriptions.allSatisfy { !$0.contains(sentinel) })
  _ = try armForceConfirmation(&parser)
  let partial = parser.consume(serialBytes(sentinel), nowMilliseconds: 1)
  let promptDescriptions =
    [
      String(describing: partial), String(reflecting: partial), String(describing: parser),
      String(reflecting: parser),
    ] + partial.events.flatMap { [String(describing: $0), String(reflecting: $0)] }
  #expect(promptDescriptions.allSatisfy { !$0.contains(sentinel) })
  #expect(guestPayload(partial.events).isEmpty)
}
