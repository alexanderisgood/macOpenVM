// SPDX-License-Identifier: Apache-2.0
import Foundation
import SharedFrameWire

#if MVO_HDR_STANDALONE
  import Qemu
#endif

/// Negotiated connection correlation. The future control-prelude owner supplies
/// this correlation only after real negotiation; this value does not perform
/// or prove negotiation, device support, source color authority or FD custody.
struct HDRNegotiatedSession: Equatable, Sendable {
  let negotiationID: UUID
  let transportConnectionEpoch: UUID
  let inputConnectionEpoch: UUID
  let limits: HDRFrameLimits

  init(
    negotiationID: UUID, transportConnectionEpoch: UUID,
    inputConnectionEpoch: UUID, limits: HDRFrameLimits
  ) throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard negotiationID != zero, transportConnectionEpoch != zero, inputConnectionEpoch != zero
    else {
      throw HDRFrameConsumerState.Failure.invalidSession
    }
    self.negotiationID = negotiationID
    self.transportConnectionEpoch = transportConnectionEpoch
    self.inputConnectionEpoch = inputConnectionEpoch
    self.limits = limits
  }
}

/// Correlation for an externally owned, already admitted mapping. No pointer,
/// FD or memory is owned here. Different IDs do not prove different backing
/// objects: the real admission adapter must establish its actual custody.
struct HDRMappingIdentity: Equatable, Sendable {
  let ownerID: UUID
  let byteCount: Int
}

struct HDRAttachmentTicket: Equatable, Sendable {
  let negotiationID: UUID
  let transportConnectionEpoch: UUID
  let inputConnectionEpoch: UUID
  let ordinal: UInt64
  let message: HDRFrameMessage
  fileprivate init(session: HDRNegotiatedSession, ordinal: UInt64, message: HDRFrameMessage) {
    negotiationID = session.negotiationID
    transportConnectionEpoch = session.transportConnectionEpoch
    inputConnectionEpoch = session.inputConnectionEpoch
    self.ordinal = ordinal
    self.message = message
  }
}

struct HDRSend: Equatable, Sendable {
  enum Purpose: Equatable, Sendable {
    case attachmentAcknowledgement, request, frameAcknowledgement
  }
  let negotiationID: UUID
  let transportConnectionEpoch: UUID
  let inputConnectionEpoch: UUID
  let ordinal: UInt64
  let purpose: Purpose
  let bytes: Data
  fileprivate init(session: HDRNegotiatedSession, ordinal: UInt64, purpose: Purpose, bytes: Data) {
    negotiationID = session.negotiationID
    transportConnectionEpoch = session.transportConnectionEpoch
    inputConnectionEpoch = session.inputConnectionEpoch
    self.ordinal = ordinal
    self.purpose = purpose
    self.bytes = bytes
  }
}

/// Immutable borrow correlation, not a fabricated GPU-completion receipt.
/// The adapter receiving this action must retain its REAL mapping owner in
/// the import and command lifetime, including after detach or a timeout.
struct HDRBorrow: Equatable, Sendable {
  let negotiationID: UUID
  let transportConnectionEpoch: UUID
  let inputConnectionEpoch: UUID
  let ordinal: UInt64
  let message: HDRFrameMessage
  let mapping: HDRMappingIdentity
  fileprivate init(
    session: HDRNegotiatedSession, ordinal: UInt64,
    message: HDRFrameMessage, mapping: HDRMappingIdentity
  ) {
    negotiationID = session.negotiationID
    transportConnectionEpoch = session.transportConnectionEpoch
    inputConnectionEpoch = session.inputConnectionEpoch
    self.ordinal = ordinal
    self.message = message
    self.mapping = mapping
  }
}

/// Serialized pure state only. It emits bytes/actions and never executes I/O,
/// touches pixels, releases mappings, creates a Metal object or enables HDR.
///
/// The methods named *Completed are adapter events, not completion proofs.
/// A production integration must restrict consumerGPUCopyCompleted to the real
/// successful private-cache copy callback. No public Boolean, decoded message,
/// cancellation or display-present callback may substitute for that event.
struct HDRFrameConsumerState: Sendable {
  enum Phase: Equatable, Sendable {
    case awaitingAttachment, admittingMappings, attachmentAcknowledgementSending
    case idle, requestSending, requested, borrowed, frameAcknowledgementSending, closed
  }
  enum Failure: Error, Equatable, Sendable {
    case invalidSession, wrongPhase, descriptorCount, negotiatedContract
    case admissionTicket, mappingIdentity, mappingBytes, mappingRejected
    case sendTicket, completionTicket, streamMismatch, surfaceMismatch
    case frameOrder, selectionRegression, selectionResourceMismatch, exhausted
    case detached, cancelled, sendFailed, gpuFailed
  }
  enum Action: Equatable, Sendable {
    case admitMappings(HDRAttachmentTicket)
    case send(HDRSend)
    case copyBorrowedSnapshot(HDRBorrow)
  }

  let session: HDRNegotiatedSession
  private(set) var phase: Phase = .awaitingAttachment
  private(set) var terminalFailure: Failure?
  private(set) var outstandingBorrow: HDRBorrow?
  private(set) var lastSequence: UInt64 = 0
  private(set) var lastContentGeneration: UInt64 = 0
  private(set) var lastSentNanoseconds: UInt64 = 0
  private var ordinal: UInt64 = 0
  private var attachment: HDRAttachmentTicket?
  private var mappings: [HDRMappingIdentity] = []
  private var surface: HDRFrameSurfaceToken?
  private var selection: HDRFrameDescriptor?
  private var pendingSend: HDRSend?

  init(afterNegotiation session: HDRNegotiatedSession) { self.session = session }

  mutating func receive(_ message: HDRFrameMessage, descriptorCount: Int) throws -> Action {
    try requireLive()
    // Message may have been constructed under weaker limits by another caller.
    // Re-admit its actual canonical header under THIS negotiated session.
    do {
      var producer = message.canonicalAcknowledgement
      producer[6] = UInt8(message.kind.rawValue)
      producer[7] = 0
      let admitted = try HDRFrameMessage(admitting: producer, limits: session.limits)
      guard admitted == message else { throw Failure.negotiatedContract }
    } catch { throw terminate(.negotiatedContract) }

    switch phase {
    case .awaitingAttachment:
      guard message.kind == .attachment else { throw terminate(.wrongPhase) }
      guard descriptorCount == 2 else { throw terminate(.descriptorCount) }
      let ticket = HDRAttachmentTicket(
        session: session, ordinal: try nextOrdinal(), message: message)
      attachment = ticket
      phase = .admittingMappings
      return .admitMappings(ticket)
    case .requested:
      guard message.kind == .frame else { throw terminate(.wrongPhase) }
      guard descriptorCount == 0 else { throw terminate(.descriptorCount) }
      guard let surface, let selection, mappings.count == 2 else {
        throw terminate(.wrongPhase)
      }
      guard message.streamEpoch == surface.streamEpoch else { throw terminate(.streamMismatch) }
      guard message.surfaceToken == surface else { throw terminate(.surfaceMismatch) }
      guard lastSequence < UInt64.max, message.sequence == lastSequence + 1,
        message.contentGeneration > lastContentGeneration,
        message.sentNanoseconds > lastSentNanoseconds,
        message.slot == Int((message.sequence - 1) % 2)
      else { throw terminate(.frameOrder) }
      let d = message.descriptor
      guard d.scanoutGeneration >= selection.scanoutGeneration else {
        throw terminate(.selectionRegression)
      }
      guard
        d.scanoutGeneration > selection.scanoutGeneration
          || (d.resourceID == selection.resourceID
            && d.resourceIncarnation == selection.resourceIncarnation)
      else { throw terminate(.selectionResourceMismatch) }
      let borrow = HDRBorrow(
        session: session, ordinal: try nextOrdinal(), message: message,
        mapping: mappings[message.slot])
      lastSequence = message.sequence
      lastContentGeneration = message.contentGeneration
      lastSentNanoseconds = message.sentNanoseconds
      self.selection = d
      outstandingBorrow = borrow
      phase = .borrowed
      return .copyBorrowedSnapshot(borrow)
    default:
      // Incoming wire violations retire the connection. Local stale completion
      // and send events below instead reject without corrupting current work.
      throw terminate(.wrongPhase)
    }
  }

  mutating func mappingsAdmitted(
    for ticket: HDRAttachmentTicket,
    first: HDRMappingIdentity, second: HDRMappingIdentity
  ) throws -> Action {
    try requireLive()
    guard phase == .admittingMappings, attachment == ticket else { throw Failure.admissionTicket }
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard first.ownerID != zero, second.ownerID != zero, first.ownerID != second.ownerID else {
      throw terminate(.mappingIdentity)
    }
    guard first.byteCount == ticket.message.descriptor.mappingBytes,
      second.byteCount == ticket.message.descriptor.mappingBytes
    else { throw terminate(.mappingBytes) }
    mappings = [first, second]
    surface = ticket.message.surfaceToken
    selection = ticket.message.descriptor
    let send = try makeSend(
      .attachmentAcknowledgement, bytes: ticket.message.canonicalAcknowledgement)
    phase = .attachmentAcknowledgementSending
    return .send(send)
  }

  mutating func mappingsRejected(for ticket: HDRAttachmentTicket) throws {
    try requireLive()
    guard phase == .admittingMappings, attachment == ticket else { throw Failure.admissionTicket }
    throw terminate(.mappingRejected)
  }

  mutating func requestFrame() throws -> Action {
    try requireLive()
    guard phase == .idle, outstandingBorrow == nil, let surface else { throw Failure.wrongPhase }
    guard lastSequence < UInt64.max else { throw terminate(.exhausted) }
    var h = MVOHDRHeader()
    h.kind = UInt32(MVO_HDR_REQUEST)
    var epoch = surface.streamEpoch.uuid
    withUnsafeBytes(of: &epoch) { source in
      withUnsafeMutableBytes(of: &h.epoch) { $0.copyMemory(from: source) }
    }
    var limits = MVOHDRLimits()
    limits.page_bytes = session.limits.pageBytes
    limits.row_alignment = session.limits.rowAlignment
    limits.maximum_mapping_bytes = session.limits.maximumMappingBytes
    var bytes = Data(count: Int(MVO_HDR_PACKET_BYTES))
    let result = bytes.withUnsafeMutableBytes {
      mvo_hdr_encode(&h, &limits, $0.baseAddress, $0.count)
    }
    guard result == MVO_HDR_OK else { throw terminate(.negotiatedContract) }
    let send = try makeSend(.request, bytes: bytes)
    phase = .requestSending
    return .send(send)
  }

  mutating func sendCompleted(_ send: HDRSend) throws {
    try requireLive()
    guard pendingSend == send else { throw Failure.sendTicket }
    switch (phase, send.purpose) {
    case (.attachmentAcknowledgementSending, .attachmentAcknowledgement):
      attachment = nil
      phase = .idle
    case (.requestSending, .request):
      phase = .requested
    case (.frameAcknowledgementSending, .frameAcknowledgement):
      outstandingBorrow = nil
      phase = .idle
    default: throw Failure.sendTicket
    }
    pendingSend = nil
  }

  mutating func sendFailed(_ send: HDRSend) throws {
    try requireLive()
    guard pendingSend == send else { throw Failure.sendTicket }
    throw terminate(.sendFailed)
  }

  mutating func consumerGPUCopyCompleted(_ borrow: HDRBorrow) throws -> Action {
    try requireLive()
    guard phase == .borrowed, outstandingBorrow == borrow else { throw Failure.completionTicket }
    let send = try makeSend(.frameAcknowledgement, bytes: borrow.message.canonicalAcknowledgement)
    phase = .frameAcknowledgementSending
    return .send(send)
  }

  mutating func consumerGPUCopyFailed(_ borrow: HDRBorrow) throws {
    try requireLive()
    guard phase == .borrowed, outstandingBorrow == borrow else { throw Failure.completionTicket }
    throw terminate(.gpuFailed)
  }

  /// No implicit ACK or mapping release. The already submitted native command
  /// must keep its actual owner alive; this reducer retains numeric state only.
  mutating func detach() { _ = terminate(.detached) }
  mutating func cancel() { _ = terminate(.cancelled) }

  private func requireLive() throws {
    if let terminalFailure { throw terminalFailure }
  }
  private mutating func terminate(_ reason: Failure) -> Failure {
    if terminalFailure == nil { terminalFailure = reason }
    phase = .closed
    pendingSend = nil
    attachment = nil
    // Preserve outstandingBorrow correlation for inspection/late completion.
    // It owns no mapping. Clearing this array never unmaps native memory.
    mappings.removeAll()
    return terminalFailure ?? reason
  }
  private mutating func nextOrdinal() throws -> UInt64 {
    guard ordinal < UInt64.max else { throw terminate(.exhausted) }
    ordinal += 1
    return ordinal
  }
  private mutating func makeSend(_ purpose: HDRSend.Purpose, bytes: Data) throws
    -> HDRSend
  {
    guard pendingSend == nil else { throw terminate(.wrongPhase) }
    let send = HDRSend(
      session: session, ordinal: try nextOrdinal(), purpose: purpose, bytes: bytes)
    pendingSend = send
    return send
  }
}
