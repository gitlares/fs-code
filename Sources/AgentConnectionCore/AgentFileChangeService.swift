import CryptoKit
import Darwin
import Foundation

public enum AgentFileChangeError: LocalizedError, Sendable, Equatable {
    case invalidPath
    case protectedPath
    case symlinkNotAllowed
    case parentMissing
    case unsupportedFile
    case fileTooLarge
    case invalidUTF8
    case fileMissing
    case fileAlreadyExists
    case emptyReplacement
    case noChanges
    case replacementNotFound
    case ambiguousReplacement
    case proposalUnavailable
    case externalChange
    case journalUnavailable
    case recordUnavailable
    case revertUnavailable
    case restoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Use a relative path inside this project."
        case .protectedPath: "Agent changes cannot edit FS Code or Git metadata."
        case .symlinkNotAllowed: "Agent changes cannot follow symbolic links."
        case .parentMissing: "The destination folder does not exist."
        case .unsupportedFile: "Only regular text files can be changed."
        case .fileTooLarge: "The file change exceeds the 1 MiB text limit."
        case .invalidUTF8: "Only UTF-8 text files without binary data can be changed."
        case .fileMissing: "The file no longer exists."
        case .fileAlreadyExists: "The file already exists."
        case .emptyReplacement: "An empty match is allowed only when creating a new file."
        case .noChanges: "The requested replacement does not change the file."
        case .replacementNotFound: "The exact text to replace was not found."
        case .ambiguousReplacement: "The exact text occurs more than once."
        case .proposalUnavailable: "This change proposal is no longer available."
        case .externalChange: "The file changed after this proposal was created."
        case .journalUnavailable: "The change journal could not be written."
        case .recordUnavailable: "The change record could not be found."
        case .revertUnavailable: "This change can no longer be reverted safely."
        case .restoreUnavailable: "This restore point can no longer be restored safely."
        }
    }
}

public enum AgentFileChangeOperation: String, Codable, Sendable {
    case create
    case replace
}

public struct AgentFileChangeProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let operation: AgentFileChangeOperation
    public let beforeText: String?
    public let afterText: String
    public let beforeSHA256: String?
    public let afterSHA256: String
    public let diff: String
    public let createdAt: Date
    public let threadID: String
    public let turnID: String
    public let revision: String
}

public enum AgentFileChangeStatus: String, Codable, Sendable {
    case prepared
    case applied
    case revertPrepared
    case reverted
    case restorePrepared
    case restored
}

public struct AgentFileChangeHunk: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recordID: UUID
    public let relativePath: String
    public let beforeText: String
    public let afterText: String
    public let oldStartLine: Int
    public let newStartLine: Int
    public var isReverted: Bool

    public var beforeLineCount: Int { Self.lineCount(beforeText) }
    public var afterLineCount: Int { Self.lineCount(afterText) }

    fileprivate let leadingContext: String
    fileprivate let trailingContext: String

    /// Returns the hunk's current UTF-16 range for use with AppKit text storage.
    /// A missing or non-unique block returns nil rather than risking the wrong edit.
    public func locate(in text: String) -> NSRange? {
        let expected = isReverted ? beforeText : afterText
        let source = text as NSString
        var uniqueMatch: NSRange?

        func consider(_ range: NSRange) -> Bool {
            guard Self.contextMatches(
                source: source,
                range: range,
                leading: leadingContext,
                trailing: trailingContext
            ) else {
                return true
            }
            guard uniqueMatch == nil else {
                uniqueMatch = nil
                return false
            }
            uniqueMatch = range
            return true
        }

        if expected.isEmpty {
            guard consider(NSRange(location: 0, length: 0)) else { return nil }
            var searchLocation = 0
            while searchLocation < source.length {
                let range = source.range(
                    of: "\n",
                    options: .literal,
                    range: NSRange(location: searchLocation, length: source.length - searchLocation)
                )
                guard range.location != NSNotFound else { break }
                searchLocation = NSMaxRange(range)
                guard consider(NSRange(location: searchLocation, length: 0)) else { return nil }
            }
            if searchLocation != source.length,
               !consider(NSRange(location: source.length, length: 0)) {
                return nil
            }
        } else {
            let expectedLength = (expected as NSString).length
            var searchLocation = 0
            while searchLocation <= source.length - expectedLength {
                let range = source.range(
                    of: expected,
                    options: .literal,
                    range: NSRange(location: searchLocation, length: source.length - searchLocation)
                )
                guard range.location != NSNotFound else { break }
                guard consider(range) else { return nil }
                searchLocation = range.location + 1
            }
        }
        return uniqueMatch
    }

    fileprivate init(
        id: String,
        recordID: UUID,
        relativePath: String,
        beforeText: String,
        afterText: String,
        oldStartLine: Int,
        newStartLine: Int,
        isReverted: Bool = false,
        leadingContext: String,
        trailingContext: String
    ) {
        self.id = id
        self.recordID = recordID
        self.relativePath = relativePath
        self.beforeText = beforeText
        self.afterText = afterText
        self.oldStartLine = oldStartLine
        self.newStartLine = newStartLine
        self.isReverted = isReverted
        self.leadingContext = leadingContext
        self.trailingContext = trailingContext
    }

    private static func contextMatches(
        source: NSString,
        range: NSRange,
        leading: String,
        trailing: String
    ) -> Bool {
        let leadingLength = (leading as NSString).length
        let trailingLength = (trailing as NSString).length
        guard range.location >= leadingLength,
              NSMaxRange(range) + trailingLength <= source.length else {
            return false
        }
        if leadingLength > 0,
           source.substring(with: NSRange(
               location: range.location - leadingLength,
               length: leadingLength
           )) != leading {
            return false
        }
        if trailingLength > 0,
           source.substring(with: NSRange(
               location: NSMaxRange(range),
               length: trailingLength
           )) != trailing {
            return false
        }
        return true
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.utf8.reduce(into: text.utf8.last == 0x0A ? 0 : 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}

private struct AgentPendingHunkRevert: Codable, Equatable, Sendable {
    let hunkID: String
    let beforeSHA256: String?
    let afterSHA256: String?
}

/// Marks a whole-turn restore that was durably prepared before any project file was written.
/// `beforeSHA256` is the content expected at preflight and `afterSHA256` is the checkpoint
/// content (or nil when the checkpoint did not contain the file).
private struct AgentPendingRestore: Codable, Equatable, Sendable {
    let beforeSHA256: String
    let afterSHA256: String?
}

public struct AgentFileChangeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let operation: AgentFileChangeOperation
    public let beforeText: String?
    public let afterText: String
    public let beforeSHA256: String?
    public let afterSHA256: String
    public let diff: String
    public let createdAt: Date
    public let threadID: String
    public let turnID: String
    public var status: AgentFileChangeStatus
    public var appliedAt: Date?
    public var revertedAt: Date?
    public var changeHunks: [AgentFileChangeHunk]

    fileprivate var pendingHunkRevert: AgentPendingHunkRevert?
    fileprivate var pendingRestore: AgentPendingRestore?

    private enum CodingKeys: String, CodingKey {
        case id, relativePath, operation, beforeText, afterText, beforeSHA256, afterSHA256
        case diff, createdAt, threadID, turnID, status, appliedAt, revertedAt
        case changeHunks, pendingHunkRevert, pendingRestore
    }

    fileprivate init(
        id: UUID,
        relativePath: String,
        operation: AgentFileChangeOperation,
        beforeText: String?,
        afterText: String,
        beforeSHA256: String?,
        afterSHA256: String,
        diff: String,
        createdAt: Date,
        threadID: String,
        turnID: String,
        status: AgentFileChangeStatus,
        appliedAt: Date?,
        revertedAt: Date?,
        changeHunks: [AgentFileChangeHunk],
        pendingHunkRevert: AgentPendingHunkRevert?,
        pendingRestore: AgentPendingRestore? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.operation = operation
        self.beforeText = beforeText
        self.afterText = afterText
        self.beforeSHA256 = beforeSHA256
        self.afterSHA256 = afterSHA256
        self.diff = diff
        self.createdAt = createdAt
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.appliedAt = appliedAt
        self.revertedAt = revertedAt
        self.changeHunks = changeHunks
        self.pendingHunkRevert = pendingHunkRevert
        self.pendingRestore = pendingRestore
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        operation = try values.decode(AgentFileChangeOperation.self, forKey: .operation)
        beforeText = try values.decodeIfPresent(String.self, forKey: .beforeText)
        afterText = try values.decode(String.self, forKey: .afterText)
        beforeSHA256 = try values.decodeIfPresent(String.self, forKey: .beforeSHA256)
        afterSHA256 = try values.decode(String.self, forKey: .afterSHA256)
        diff = try values.decode(String.self, forKey: .diff)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        threadID = try values.decode(String.self, forKey: .threadID)
        turnID = try values.decode(String.self, forKey: .turnID)
        status = try values.decode(AgentFileChangeStatus.self, forKey: .status)
        appliedAt = try values.decodeIfPresent(Date.self, forKey: .appliedAt)
        revertedAt = try values.decodeIfPresent(Date.self, forKey: .revertedAt)
        changeHunks = try values.decodeIfPresent(
            [AgentFileChangeHunk].self,
            forKey: .changeHunks
        ) ?? []
        pendingHunkRevert = try values.decodeIfPresent(
            AgentPendingHunkRevert.self,
            forKey: .pendingHunkRevert
        )
        pendingRestore = try values.decodeIfPresent(AgentPendingRestore.self, forKey: .pendingRestore)
    }
}

/// The only host-side writer used by agent tools. It stages one exact text edit,
/// then applies it after its caller has completed the active-turn safety checks.
public actor AgentFileChangeService {
    public static let maximumTextBytes = 1_048_576
    private static let maximumStagedProposals = 64
    private static let maximumHistoryEntries = 5_000
    private static let maximumJournalBytes = 4_194_304
    private static let maximumJournalTotalBytes = 16_777_216
    private static let maximumStagedTextBytes = 16_777_216
    private static let maximumDiffMatrixCells = 1_000_000
    private static let hunkContextLineCount = 3

    public let projectURL: URL
    public let journalURL: URL

    private let fileManager = FileManager.default
    private var staged: [UUID: AgentFileChangeProposal] = [:]

    public init(projectURL: URL) throws {
        let canonical = projectURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentFileChangeError.invalidPath
        }
        self.projectURL = canonical
        journalURL = canonical
            .appendingPathComponent(".fscode", isDirectory: true)
            .appendingPathComponent("agent-changes", isDirectory: true)
    }

    public func read(relativePath: String) throws -> String? {
        let target = try validatedTarget(for: relativePath, allowMissingTarget: true)
        guard target.exists else { return nil }
        return try readText(at: target.url).text
    }

    public func stageEdit(
        relativePath: String,
        oldText: String,
        newText: String,
        threadID: String,
        turnID: String
    ) throws -> AgentFileChangeProposal {
        guard !threadID.isEmpty, !turnID.isEmpty else {
            throw AgentFileChangeError.proposalUnavailable
        }
        try validateText(newText)
        let target = try validatedTarget(for: relativePath, allowMissingTarget: true)
        let beforeText: String?
        let afterText: String
        let operation: AgentFileChangeOperation

        if target.exists {
            guard !oldText.isEmpty else { throw AgentFileChangeError.emptyReplacement }
            let current = try readText(at: target.url).text
            let matches = Self.matchRanges(of: oldText, in: current, limit: 2)
            guard !matches.isEmpty else { throw AgentFileChangeError.replacementNotFound }
            guard matches.count == 1 else { throw AgentFileChangeError.ambiguousReplacement }
            beforeText = current
            afterText = current.replacingCharacters(in: matches[0], with: newText)
            operation = .replace
        } else {
            guard oldText.isEmpty else { throw AgentFileChangeError.fileMissing }
            beforeText = nil
            afterText = newText
            operation = .create
        }

        try validateText(afterText)
        if operation == .replace, beforeText == afterText {
            throw AgentFileChangeError.noChanges
        }
        let beforeHash = beforeText.map(Self.sha256)
        let afterHash = Self.sha256(afterText)
        let id = UUID()
        let revision = Self.sha256(
            [id.uuidString, relativePath, beforeHash ?? "missing", afterHash, threadID, turnID]
                .joined(separator: "\u{0}")
        )
        let proposal = AgentFileChangeProposal(
            id: id,
            relativePath: relativePath,
            operation: operation,
            beforeText: beforeText,
            afterText: afterText,
            beforeSHA256: beforeHash,
            afterSHA256: afterHash,
            diff: Self.unifiedDiff(path: relativePath, before: beforeText, after: afterText),
            createdAt: Date(),
            threadID: threadID,
            turnID: turnID,
            revision: revision
        )
        var stagedBytes = staged.values.reduce(0) {
            $0 + ($1.beforeText?.utf8.count ?? 0) + $1.afterText.utf8.count
        }
        let proposalBytes = (proposal.beforeText?.utf8.count ?? 0) + proposal.afterText.utf8.count
        while staged.count >= Self.maximumStagedProposals
                || stagedBytes + proposalBytes > Self.maximumStagedTextBytes,
              let oldest = staged.values.min(by: { $0.createdAt < $1.createdAt }) {
            stagedBytes -= (oldest.beforeText?.utf8.count ?? 0) + oldest.afterText.utf8.count
            staged.removeValue(forKey: oldest.id)
        }
        staged[id] = proposal
        return proposal
    }

    public func discard(_ proposalID: UUID) {
        staged.removeValue(forKey: proposalID)
    }

    public func discardAll() {
        staged.removeAll()
    }

    public func applyApproved(_ proposal: AgentFileChangeProposal) throws -> AgentFileChangeRecord {
        try Task.checkCancellation()
        guard let original = staged[proposal.id], original == proposal else {
            throw AgentFileChangeError.proposalUnavailable
        }
        guard Self.sha256(proposal.afterText) == proposal.afterSHA256,
              proposal.beforeText.map(Self.sha256) == proposal.beforeSHA256 else {
            throw AgentFileChangeError.proposalUnavailable
        }

        let target = try validatedTarget(for: proposal.relativePath, allowMissingTarget: true)
        let current = try currentText(for: target)
        guard current.map(Self.sha256) == proposal.beforeSHA256 else {
            throw AgentFileChangeError.externalChange
        }
        if proposal.operation == .create, target.exists {
            throw AgentFileChangeError.fileAlreadyExists
        }
        if proposal.operation == .replace, !target.exists {
            throw AgentFileChangeError.fileMissing
        }

        let now = Date()
        let changeHunks = Self.makeChangeHunks(
            recordID: proposal.id,
            relativePath: proposal.relativePath,
            before: proposal.beforeText,
            after: proposal.afterText
        )
        var record = AgentFileChangeRecord(
            id: proposal.id,
            relativePath: proposal.relativePath,
            operation: proposal.operation,
            beforeText: proposal.beforeText,
            afterText: proposal.afterText,
            beforeSHA256: proposal.beforeSHA256,
            afterSHA256: proposal.afterSHA256,
            diff: proposal.diff,
            createdAt: proposal.createdAt,
            threadID: proposal.threadID,
            turnID: proposal.turnID,
            status: .prepared,
            appliedAt: now,
            revertedAt: nil,
            changeHunks: changeHunks,
            pendingHunkRevert: nil
        )

        try persist(record)
        let permissions = try permissionsForWrite(to: target)
        let revalidated = try validatedTarget(
            for: proposal.relativePath,
            allowMissingTarget: true
        )
        let revalidatedText = try currentText(for: revalidated)
        guard revalidatedText.map(Self.sha256) == proposal.beforeSHA256,
              revalidated.exists == target.exists else {
            throw AgentFileChangeError.externalChange
        }
        try Task.checkCancellation()
        do {
            try writeAtomically(
                proposal.afterText,
                to: target.url,
                permissions: permissions,
                requireMissing: proposal.operation == .create
            )
        } catch {
            throw error
        }
        staged.removeValue(forKey: proposal.id)

        record.status = .applied
        // A PREPARED record already contains the full audit data. If this final
        // status update fails, history reconciles it from the current content hash.
        try? persist(record)
        return record
    }

    public func history(relativePath: String? = nil) throws -> [AgentFileChangeRecord] {
        if let relativePath {
            _ = try validatedRelativePathComponents(relativePath)
        }
        guard fileManager.fileExists(atPath: journalURL.path) else { return [] }
        try validateJournalDirectoryIfPresent()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: journalURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw AgentFileChangeError.journalUnavailable
        }
        let recordURLs = urls.filter { $0.pathExtension == "json" }
        guard recordURLs.count <= Self.maximumHistoryEntries else {
            throw AgentFileChangeError.journalUnavailable
        }

        var records: [AgentFileChangeRecord] = []
        var totalBytes = 0
        for url in recordURLs {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0,
                  info.st_size <= Self.maximumJournalBytes else {
                throw AgentFileChangeError.journalUnavailable
            }
            totalBytes += Int(info.st_size)
            guard totalBytes <= Self.maximumJournalTotalBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= Self.maximumJournalBytes,
                  var record = try? JSONDecoder().decode(AgentFileChangeRecord.self, from: data) else {
                throw AgentFileChangeError.journalUnavailable
            }
            guard record.beforeText.map(Self.sha256) == record.beforeSHA256,
                  Self.sha256(record.afterText) == record.afterSHA256,
                  (try? validatedRelativePathComponents(record.relativePath)) != nil else {
                throw AgentFileChangeError.journalUnavailable
            }
            if record.changeHunks.isEmpty,
               record.beforeText != record.afterText {
                record.changeHunks = Self.makeChangeHunks(
                    recordID: record.id,
                    relativePath: record.relativePath,
                    before: record.beforeText,
                    after: record.afterText
                )
                if record.status == .reverted {
                    record.changeHunks = record.changeHunks.map { hunk in
                        var reverted = hunk
                        reverted.isReverted = true
                        return reverted
                    }
                }
            }
            guard Self.hunksAreValid(record.changeHunks, for: record) else {
                throw AgentFileChangeError.journalUnavailable
            }
            if let relativePath, record.relativePath != relativePath { continue }
            record = reconcile(record)
            records.append(record)
        }
        return records.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// Returns every project-relative path affected by restoring this chat to immediately
    /// before `turnID`. This performs the same chain validation as `restorePoint` but never
    /// writes, so the workspace can authorize all dirty buffers before a batch starts.
    public func restorePointPaths(threadID: String, turnID: String) throws -> [String] {
        try restorePlans(threadID: threadID, turnID: turnID).map(\.relativePath)
    }

    /// Restores this chat to the checkpoint immediately before `turnID`.
    ///
    /// All records from that turn onward which touch an affected file must form one continuous,
    /// fully-applied chain in this same chat. The entire batch is hash-preflighted before any
    /// write. A durable prepared state lets a later launch report or reconcile an interrupted
    /// restore rather than silently treating a partial batch as successful.
    public func restorePoint(threadID: String, turnID: String) throws -> [AgentFileChangeRecord] {
        try Task.checkCancellation()
        let plans = try restorePlans(threadID: threadID, turnID: turnID)
        guard !plans.isEmpty else { throw AgentFileChangeError.restoreUnavailable }

        for plan in plans {
            let target = try validatedTarget(for: plan.relativePath, allowMissingTarget: true)
            guard target.exists,
                  let current = try currentText(for: target),
                  Self.sha256(current) == plan.expectedSHA256 else {
                throw AgentFileChangeError.externalChange
            }
        }

        var preparedRecords: [AgentFileChangeRecord] = []
        for plan in plans {
            for var record in plan.records {
                record.status = .restorePrepared
                record.pendingRestore = AgentPendingRestore(
                    beforeSHA256: plan.expectedSHA256,
                    afterSHA256: plan.restoredSHA256
                )
                try persist(record)
                preparedRecords.append(record)
            }
        }

        // Recheck every path after durable preparation. No cancellation point follows this:
        // once writes start, this method either completes or leaves an explicit prepared state.
        for plan in plans {
            let target = try validatedTarget(for: plan.relativePath, allowMissingTarget: true)
            guard target.exists,
                  let current = try currentText(for: target),
                  Self.sha256(current) == plan.expectedSHA256 else {
                throw AgentFileChangeError.externalChange
            }
        }

        var written: [WrittenRestore] = []
        do {
            for plan in plans {
                let target = try validatedTarget(for: plan.relativePath, allowMissingTarget: false)
                guard let current = try currentText(for: target),
                      Self.sha256(current) == plan.expectedSHA256 else {
                    throw AgentFileChangeError.externalChange
                }
                let permissions = try permissionsForWrite(to: target)
                if let checkpointText = plan.checkpointText {
                    try writeAtomically(checkpointText, to: target.url, permissions: permissions, requireMissing: false)
                } else {
                    guard unlink(target.url.path) == 0 else { throw AgentFileChangeError.restoreUnavailable }
                }
                written.append(WrittenRestore(plan: plan, permissions: permissions))
            }
        } catch {
            // Best effort only: never overwrite an intervening external change while unwinding.
            for writtenRestore in written.reversed() {
                let plan = writtenRestore.plan
                guard let target = try? validatedTarget(for: plan.relativePath, allowMissingTarget: true) else { continue }
                if target.exists {
                    guard let current = try? currentText(for: target),
                          Self.sha256(current) == plan.restoredSHA256,
                          let permissions = try? permissionsForWrite(to: target) else { continue }
                    try? writeAtomically(plan.originalText, to: target.url, permissions: permissions, requireMissing: false)
                } else if plan.restoredSHA256 == nil {
                    try? writeAtomically(
                        plan.originalText,
                        to: target.url,
                        permissions: writtenRestore.permissions,
                        requireMissing: true
                    )
                }
            }
            throw error
        }

        for index in preparedRecords.indices {
            preparedRecords[index].status = .restored
            preparedRecords[index].revertedAt = Date()
            preparedRecords[index].pendingRestore = nil
            preparedRecords[index].changeHunks = preparedRecords[index].changeHunks.map { hunk in
                var restored = hunk
                restored.isReverted = true
                return restored
            }
            try? persist(preparedRecords[index])
        }
        return preparedRecords
    }

    public func revert(recordID: UUID) throws -> AgentFileChangeRecord {
        try Task.checkCancellation()
        guard var record = try history().first(where: { $0.id == recordID }) else {
            throw AgentFileChangeError.recordUnavailable
        }
        guard record.status == .applied else { throw AgentFileChangeError.revertUnavailable }
        let target = try validatedTarget(for: record.relativePath, allowMissingTarget: true)
        let current = try currentText(for: target)
        guard current.map(Self.sha256) == record.afterSHA256 else {
            throw AgentFileChangeError.externalChange
        }

        record.status = .revertPrepared
        record.revertedAt = Date()
        try persist(record)

        if let beforeText = record.beforeText {
            let permissions = try permissionsForWrite(to: target)
            let revalidated = try validatedTarget(for: record.relativePath, allowMissingTarget: false)
            guard try currentText(for: revalidated).map(Self.sha256) == record.afterSHA256 else {
                throw AgentFileChangeError.externalChange
            }
            try Task.checkCancellation()
            try writeAtomically(
                beforeText,
                to: target.url,
                permissions: permissions,
                requireMissing: false
            )
        } else {
            let revalidated = try validatedTarget(for: record.relativePath, allowMissingTarget: false)
            guard try currentText(for: revalidated).map(Self.sha256) == record.afterSHA256 else {
                throw AgentFileChangeError.externalChange
            }
            try Task.checkCancellation()
            guard unlink(revalidated.url.path) == 0 else {
                throw AgentFileChangeError.revertUnavailable
            }
        }

        record.status = .reverted
        record.changeHunks = record.changeHunks.map { hunk in
            var reverted = hunk
            reverted.isReverted = true
            return reverted
        }
        record.pendingHunkRevert = nil
        try? persist(record)
        return record
    }

    public func revertHunk(recordID: UUID, hunkID: String) throws -> AgentFileChangeRecord {
        try Task.checkCancellation()
        guard var record = try history().first(where: { $0.id == recordID }) else {
            throw AgentFileChangeError.recordUnavailable
        }
        guard record.status == .applied,
              record.pendingHunkRevert == nil,
              let hunkIndex = record.changeHunks.firstIndex(where: { $0.id == hunkID }),
              !record.changeHunks[hunkIndex].isReverted else {
            throw AgentFileChangeError.revertUnavailable
        }

        let target = try validatedTarget(for: record.relativePath, allowMissingTarget: false)
        guard let current = try currentText(for: target),
              let range = record.changeHunks[hunkIndex].locate(in: current) else {
            throw AgentFileChangeError.revertUnavailable
        }
        let updated = (current as NSString).replacingCharacters(
            in: range,
            with: record.changeHunks[hunkIndex].beforeText
        )
        try validateText(updated)

        let currentHash = Self.sha256(current)
        let remainingHunksReverted = record.changeHunks.indices.allSatisfy {
            $0 == hunkIndex || record.changeHunks[$0].isReverted
        }
        let removeCreatedFile = record.operation == .create
            && remainingHunksReverted
            && updated.isEmpty
            && currentHash == record.afterSHA256
        let updatedHash: String? = removeCreatedFile ? nil : Self.sha256(updated)
        let permissions = removeCreatedFile ? nil : try permissionsForWrite(to: target)

        record.pendingHunkRevert = AgentPendingHunkRevert(
            hunkID: hunkID,
            beforeSHA256: currentHash,
            afterSHA256: updatedHash
        )
        try persist(record)

        let revalidated = try validatedTarget(for: record.relativePath, allowMissingTarget: false)
        guard let revalidatedText = try currentText(for: revalidated),
              Self.sha256(revalidatedText) == currentHash else {
            throw AgentFileChangeError.externalChange
        }
        try Task.checkCancellation()
        if removeCreatedFile {
            guard unlink(revalidated.url.path) == 0 else {
                throw AgentFileChangeError.revertUnavailable
            }
        } else {
            try writeAtomically(
                updated,
                to: revalidated.url,
                permissions: permissions ?? 0o644,
                requireMissing: false
            )
        }

        record.changeHunks[hunkIndex].isReverted = true
        record.pendingHunkRevert = nil
        if remainingHunksReverted {
            record.status = .reverted
            record.revertedAt = Date()
        }
        try? persist(record)
        return record
    }

    private func reconcile(_ record: AgentFileChangeRecord) -> AgentFileChangeRecord {
        let current: String?
        do {
            let target = try validatedTarget(for: record.relativePath, allowMissingTarget: true)
            current = try currentText(for: target)
        } catch { return record }
        let currentHash = current.map(Self.sha256)
        var reconciled = record

        if let pending = record.pendingRestore {
            if currentHash == pending.afterSHA256 {
                reconciled.status = .restored
                reconciled.revertedAt = reconciled.revertedAt ?? Date()
                reconciled.pendingRestore = nil
                reconciled.changeHunks = reconciled.changeHunks.map { hunk in
                    var restored = hunk
                    restored.isReverted = true
                    return restored
                }
                try? persist(reconciled)
            } else if currentHash == pending.beforeSHA256 {
                reconciled.status = .applied
                reconciled.pendingRestore = nil
                try? persist(reconciled)
            }
            return reconciled
        }

        if let pending = record.pendingHunkRevert {
            if currentHash == pending.afterSHA256,
               let index = reconciled.changeHunks.firstIndex(where: { $0.id == pending.hunkID }) {
                reconciled.changeHunks[index].isReverted = true
                reconciled.pendingHunkRevert = nil
                if reconciled.changeHunks.allSatisfy({ $0.isReverted }) {
                    reconciled.status = .reverted
                    reconciled.revertedAt = reconciled.revertedAt ?? Date()
                }
                try? persist(reconciled)
            } else if currentHash == pending.beforeSHA256 {
                reconciled.pendingHunkRevert = nil
                try? persist(reconciled)
            }
            return reconciled
        }

        guard record.status == .prepared || record.status == .revertPrepared else {
            return record
        }
        if record.status == .prepared, currentHash == record.afterSHA256 {
            reconciled.status = .applied
        } else if record.status == .revertPrepared, currentHash == record.beforeSHA256 {
            reconciled.status = .reverted
            reconciled.changeHunks = reconciled.changeHunks.map { hunk in
                var reverted = hunk
                reverted.isReverted = true
                return reverted
            }
        } else if record.status == .revertPrepared, currentHash == record.afterSHA256 {
            reconciled.status = .applied
            reconciled.revertedAt = nil
            reconciled.changeHunks = reconciled.changeHunks.map { hunk in
                var applied = hunk
                applied.isReverted = false
                return applied
            }
        } else {
            return record
        }
        try? persist(reconciled)
        return reconciled
    }

    private struct RestorePlan {
        let relativePath: String
        let records: [AgentFileChangeRecord]
        let checkpointText: String?
        let expectedSHA256: String
        let restoredSHA256: String?
        let originalText: String
    }

    private struct WrittenRestore {
        let plan: RestorePlan
        let permissions: NSNumber
    }

    private func restorePlans(threadID: String, turnID: String) throws -> [RestorePlan] {
        guard !threadID.isEmpty, !turnID.isEmpty else {
            throw AgentFileChangeError.restoreUnavailable
        }
        let all = try history().sorted(by: Self.isEarlier)
        let checkpointRecords = all.filter { $0.threadID == threadID && $0.turnID == turnID }
        guard let checkpoint = checkpointRecords.min(by: Self.isEarlier),
              checkpointRecords.allSatisfy({ $0.status == .applied && $0.pendingRestore == nil }) else {
            throw AgentFileChangeError.restoreUnavailable
        }
        let selected = all.filter {
            $0.threadID == threadID
                && Self.isAtOrAfter($0, checkpoint)
                && !Self.isFullyInactiveRestoreRecord($0)
        }
        guard selected.allSatisfy({
            $0.status == .applied
                && $0.pendingRestore == nil
                && !$0.changeHunks.contains(where: \.isReverted)
        }) else {
            throw AgentFileChangeError.restoreUnavailable
        }

        let selectedPaths = Set(selected.map(\.relativePath))
        var plans: [RestorePlan] = []
        for path in selectedPaths.sorted() {
            let chain = all.filter {
                $0.relativePath == path
                    && Self.isAtOrAfter($0, checkpoint)
                    && !Self.isFullyInactiveRestoreRecord($0)
            }
            guard !chain.isEmpty,
                  chain.allSatisfy({
                      $0.threadID == threadID
                          && $0.status == .applied
                          && $0.pendingRestore == nil
                          && !$0.changeHunks.contains(where: \.isReverted)
                  }),
                  let first = chain.first,
                  let last = chain.last else {
                throw AgentFileChangeError.restoreUnavailable
            }
            for (previous, next) in zip(chain, chain.dropFirst()) {
                guard previous.afterSHA256 == next.beforeSHA256 else {
                    throw AgentFileChangeError.restoreUnavailable
                }
            }
            plans.append(RestorePlan(
                relativePath: path,
                records: chain,
                checkpointText: first.beforeText,
                expectedSHA256: last.afterSHA256,
                restoredSHA256: first.beforeSHA256,
                originalText: last.afterText
            ))
        }
        return plans
    }

    private static func isEarlier(_ lhs: AgentFileChangeRecord, _ rhs: AgentFileChangeRecord) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt
    }

    private static func isAtOrAfter(_ record: AgentFileChangeRecord, _ checkpoint: AgentFileChangeRecord) -> Bool {
        !isEarlier(record, checkpoint)
    }

    private static func isFullyInactiveRestoreRecord(_ record: AgentFileChangeRecord) -> Bool {
        (record.status == .reverted || record.status == .restored)
            && record.pendingRestore == nil
            && record.changeHunks.allSatisfy(\.isReverted)
    }

    private struct ValidatedTarget {
        let url: URL
        let exists: Bool
    }

    private func validatedTarget(
        for relativePath: String,
        allowMissingTarget: Bool
    ) throws -> ValidatedTarget {
        let components = try validatedRelativePathComponents(relativePath)

        var rootInfo = stat()
        guard lstat(projectURL.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (rootInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw AgentFileChangeError.invalidPath
        }

        let target = projectURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
        guard target.path.hasPrefix(rootPrefix) else { throw AgentFileChangeError.invalidPath }

        var current = projectURL
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw AgentFileChangeError.symlinkNotAllowed
                }
                if index < components.count - 1 {
                    guard (info.st_mode & S_IFMT) == S_IFDIR else {
                        throw AgentFileChangeError.parentMissing
                    }
                } else {
                    guard (info.st_mode & S_IFMT) == S_IFREG else {
                        throw AgentFileChangeError.unsupportedFile
                    }
                    return ValidatedTarget(url: target, exists: true)
                }
            } else if errno == ENOENT {
                guard index == components.count - 1, allowMissingTarget else {
                    throw AgentFileChangeError.parentMissing
                }
                return ValidatedTarget(url: target, exists: false)
            } else {
                throw AgentFileChangeError.invalidPath
            }
        }
        throw AgentFileChangeError.invalidPath
    }

    private func validatedRelativePathComponents(_ relativePath: String) throws -> [Substring] {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 4_096,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\u{0}") else {
            throw AgentFileChangeError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentFileChangeError.invalidPath
        }
        let firstComponent = components[0].lowercased()
        guard firstComponent != ".fscode", firstComponent != ".git" else {
            throw AgentFileChangeError.protectedPath
        }
        return components
    }

    private func currentText(for target: ValidatedTarget) throws -> String? {
        guard target.exists else { return nil }
        return try readText(at: target.url).text
    }

    private func readText(at url: URL) throws -> (text: String, permissions: NSNumber) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw AgentFileChangeError.fileMissing
        }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumTextBytes else {
            throw AgentFileChangeError.fileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AgentFileChangeError.fileMissing
        }
        guard data.count <= Self.maximumTextBytes else { throw AgentFileChangeError.fileTooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AgentFileChangeError.invalidUTF8
        }
        return (text, attributes[.posixPermissions] as? NSNumber ?? 0o644)
    }

    private func permissionsForWrite(to target: ValidatedTarget) throws -> NSNumber {
        guard target.exists else { return 0o644 }
        return try readText(at: target.url).permissions
    }

    private func validateText(_ text: String) throws {
        guard text.utf8.count <= Self.maximumTextBytes else {
            throw AgentFileChangeError.fileTooLarge
        }
        guard !text.utf8.contains(0) else { throw AgentFileChangeError.invalidUTF8 }
    }

    private func ensureJournalDirectory() throws {
        let metadata = projectURL.appendingPathComponent(".fscode", isDirectory: true)
        for url in [metadata, journalURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw AgentFileChangeError.journalUnavailable
                }
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw AgentFileChangeError.journalUnavailable
                }
            } else if errno == ENOENT {
                do {
                    try fileManager.createDirectory(
                        at: url,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    throw AgentFileChangeError.journalUnavailable
                }
            } else {
                throw AgentFileChangeError.journalUnavailable
            }
        }
    }

    private func validateJournalDirectoryIfPresent() throws {
        let metadata = projectURL.appendingPathComponent(".fscode", isDirectory: true)
        for url in [metadata, journalURL] {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_mode & S_IFMT) != S_IFLNK else {
                throw AgentFileChangeError.journalUnavailable
            }
        }
    }

    private func persist(_ record: AgentFileChangeRecord) throws {
        try ensureJournalDirectory()
        let url = journalURL.appendingPathComponent(record.id.uuidString + ".json")
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= Self.maximumJournalBytes else {
                throw AgentFileChangeError.journalUnavailable
            }
            let entries = try fileManager.contentsOfDirectory(
                at: journalURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            guard entries.count <= Self.maximumHistoryEntries else {
                throw AgentFileChangeError.journalUnavailable
            }
            var totalBytes = 0
            for entry in entries {
                var info = stat()
                guard lstat(entry.path, &info) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_size >= 0,
                      info.st_size <= Self.maximumJournalBytes else {
                    throw AgentFileChangeError.journalUnavailable
                }
                if entry != url { totalBytes += Int(info.st_size) }
            }
            guard totalBytes + data.count <= Self.maximumJournalTotalBytes else {
                throw AgentFileChangeError.journalUnavailable
            }
            try data.write(to: url, options: .atomic)
        } catch {
            if let error = error as? AgentFileChangeError { throw error }
            throw AgentFileChangeError.journalUnavailable
        }
    }

    private func writeAtomically(
        _ text: String,
        to target: URL,
        permissions: NSNumber,
        requireMissing: Bool
    ) throws {
        let parent = target.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".fscode-write-\(UUID().uuidString)")
        do {
            try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if requireMissing {
                guard link(temporary.path, target.path) == 0 else {
                    throw AgentFileChangeError.externalChange
                }
                _ = unlink(temporary.path)
            } else {
                guard rename(temporary.path, target.path) == 0 else {
                    throw AgentFileChangeError.externalChange
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func matchRanges(
        of needle: String,
        in haystack: String,
        limit: Int
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart <= haystack.endIndex,
              let range = haystack.range(
                of: needle,
                options: .literal,
                range: searchStart..<haystack.endIndex
              ) {
            ranges.append(range)
            if ranges.count >= limit { break }
            guard range.lowerBound < haystack.endIndex else { break }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return ranges
    }

    private struct LineMatch {
        let oldIndex: Int
        let newIndex: Int
    }

    private static func makeChangeHunks(
        recordID: UUID,
        relativePath: String,
        before: String?,
        after: String
    ) -> [AgentFileChangeHunk] {
        let oldLines = lineTokens(before ?? "")
        let newLines = lineTokens(after)
        if before == nil, after.isEmpty {
            let stableID = sha256([
                recordID.uuidString,
                relativePath,
                "1",
                "1",
                "",
                "",
                "",
                "",
            ].joined(separator: "\u{0}"))
            return [AgentFileChangeHunk(
                id: stableID,
                recordID: recordID,
                relativePath: relativePath,
                beforeText: "",
                afterText: "",
                oldStartLine: 1,
                newStartLine: 1,
                leadingContext: "",
                trailingContext: ""
            )]
        }
        guard oldLines != newLines else { return [] }

        let matches = boundedLineMatches(oldLines: oldLines, newLines: newLines)
        var hunks: [AgentFileChangeHunk] = []
        for matchIndex in 1..<matches.count {
            let previous = matches[matchIndex - 1]
            let next = matches[matchIndex]
            let oldStart = previous.oldIndex + 1
            let newStart = previous.newIndex + 1
            let oldEnd = next.oldIndex
            let newEnd = next.newIndex
            guard oldStart < oldEnd || newStart < newEnd else { continue }

            var leadingMatches: [LineMatch] = []
            var cursor = matchIndex - 1
            while cursor > 0,
                  leadingMatches.count < hunkContextLineCount {
                let pair = matches[cursor]
                guard pair.oldIndex >= 0, pair.newIndex >= 0 else { break }
                if let nearest = leadingMatches.first,
                   pair.oldIndex + 1 != nearest.oldIndex
                    || pair.newIndex + 1 != nearest.newIndex {
                    break
                }
                leadingMatches.insert(pair, at: 0)
                cursor -= 1
            }

            var trailingMatches: [LineMatch] = []
            cursor = matchIndex
            while cursor < matches.count - 1,
                  trailingMatches.count < hunkContextLineCount {
                let pair = matches[cursor]
                guard pair.oldIndex < oldLines.count, pair.newIndex < newLines.count else { break }
                if let nearest = trailingMatches.last,
                   nearest.oldIndex + 1 != pair.oldIndex
                    || nearest.newIndex + 1 != pair.newIndex {
                    break
                }
                trailingMatches.append(pair)
                cursor += 1
            }

            let beforeText = oldLines[oldStart..<oldEnd].joined()
            let afterText = newLines[newStart..<newEnd].joined()
            let leadingContext = leadingMatches.map { oldLines[$0.oldIndex] }.joined()
            let trailingContext = trailingMatches.map { oldLines[$0.oldIndex] }.joined()
            let stableID = sha256([
                recordID.uuidString,
                relativePath,
                String(oldStart + 1),
                String(newStart + 1),
                beforeText,
                afterText,
                leadingContext,
                trailingContext,
            ].joined(separator: "\u{0}"))
            hunks.append(AgentFileChangeHunk(
                id: stableID,
                recordID: recordID,
                relativePath: relativePath,
                beforeText: beforeText,
                afterText: afterText,
                oldStartLine: oldStart + 1,
                newStartLine: newStart + 1,
                leadingContext: leadingContext,
                trailingContext: trailingContext
            ))
        }
        return hunks
    }

    /// Uses a bounded LCS matrix for separated line hunks. Files beyond the cap
    /// conservatively become one larger hunk between their common prefix/suffix.
    private static func boundedLineMatches(
        oldLines: [String],
        newLines: [String]
    ) -> [LineMatch] {
        let oldCount = oldLines.count
        let newCount = newLines.count
        let withinMatrixLimit = oldCount == 0
            || newCount <= maximumDiffMatrixCells / oldCount
        guard withinMatrixLimit else {
            var prefix = 0
            while prefix < oldCount,
                  prefix < newCount,
                  oldLines[prefix] == newLines[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < oldCount - prefix,
                  suffix < newCount - prefix,
                  oldLines[oldCount - suffix - 1] == newLines[newCount - suffix - 1] {
                suffix += 1
            }
            var result = [LineMatch(oldIndex: -1, newIndex: -1)]
            result += (0..<prefix).map { LineMatch(oldIndex: $0, newIndex: $0) }
            for offset in (0..<suffix).reversed() {
                result.append(LineMatch(
                    oldIndex: oldCount - offset - 1,
                    newIndex: newCount - offset - 1
                ))
            }
            result.append(LineMatch(oldIndex: oldCount, newIndex: newCount))
            return result
        }

        let columns = newCount + 1
        var matrix = [UInt32](repeating: 0, count: (oldCount + 1) * columns)
        if oldCount > 0, newCount > 0 {
            for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
                for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
                    let index = oldIndex * columns + newIndex
                    if oldLines[oldIndex] == newLines[newIndex] {
                        matrix[index] = matrix[(oldIndex + 1) * columns + newIndex + 1] + 1
                    } else {
                        matrix[index] = max(
                            matrix[(oldIndex + 1) * columns + newIndex],
                            matrix[oldIndex * columns + newIndex + 1]
                        )
                    }
                }
            }
        }

        var result = [LineMatch(oldIndex: -1, newIndex: -1)]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldCount, newIndex < newCount {
            if oldLines[oldIndex] == newLines[newIndex] {
                result.append(LineMatch(oldIndex: oldIndex, newIndex: newIndex))
                oldIndex += 1
                newIndex += 1
            } else if matrix[(oldIndex + 1) * columns + newIndex]
                        >= matrix[oldIndex * columns + newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        result.append(LineMatch(oldIndex: oldCount, newIndex: newCount))
        return result
    }

    private static func hunksAreValid(
        _ hunks: [AgentFileChangeHunk],
        for record: AgentFileChangeRecord
    ) -> Bool {
        let expected = makeChangeHunks(
            recordID: record.id,
            relativePath: record.relativePath,
            before: record.beforeText,
            after: record.afterText
        )
        guard expected.count == hunks.count,
              Set(hunks.map(\.id)).count == hunks.count else {
            return false
        }
        for (actual, generated) in zip(hunks, expected) {
            guard actual.id == generated.id,
                  actual.recordID == record.id,
                  actual.relativePath == record.relativePath,
                  actual.beforeText == generated.beforeText,
                  actual.afterText == generated.afterText,
                  actual.oldStartLine == generated.oldStartLine,
                  actual.newStartLine == generated.newStartLine,
                  actual.leadingContext == generated.leadingContext,
                  actual.trailingContext == generated.trailingContext else {
                return false
            }
        }
        if let pending = record.pendingHunkRevert,
           !hunks.contains(where: { $0.id == pending.hunkID }) {
            return false
        }
        return true
    }

    private static func lineTokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        let bytes = text.utf8
        var start = bytes.startIndex
        var cursor = start
        while cursor < bytes.endIndex {
            if bytes[cursor] == 0x0A {
                let end = bytes.index(after: cursor)
                result.append(String(decoding: bytes[start..<end], as: UTF8.self))
                start = end
                cursor = end
            } else {
                cursor = bytes.index(after: cursor)
            }
        }
        if start < bytes.endIndex {
            result.append(String(decoding: bytes[start..<bytes.endIndex], as: UTF8.self))
        }
        return result
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func unifiedDiff(path: String, before: String?, after: String) -> String {
        let oldLines = before.map(lines) ?? []
        let newLines = lines(after)
        let oldHeader = before == nil ? "/dev/null" : "a/\(path)"
        var output = "--- \(oldHeader)\n+++ b/\(path)\n"
        var prefix = 0
        while prefix < oldLines.count,
              prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1] {
            suffix += 1
        }
        let context = 3
        let oldStart = max(0, prefix - context)
        let newStart = max(0, prefix - context)
        let oldChangedEnd = oldLines.count - suffix
        let newChangedEnd = newLines.count - suffix
        let oldEnd = min(oldLines.count, oldChangedEnd + context)
        let newEnd = min(newLines.count, newChangedEnd + context)
        output += "@@ -\(oldStart + 1),\(oldEnd - oldStart) +\(newStart + 1),\(newEnd - newStart) @@\n"
        for line in oldLines[oldStart..<prefix] { output += " \(line)\n" }
        for line in oldLines[prefix..<oldChangedEnd] { output += "-\(line)\n" }
        if let before, !before.isEmpty, !before.hasSuffix("\n"), oldChangedEnd == oldLines.count {
            output += "\\ No newline at end of file\n"
        }
        for line in newLines[prefix..<newChangedEnd] { output += "+\(line)\n" }
        if !after.isEmpty, !after.hasSuffix("\n"), newChangedEnd == newLines.count {
            output += "\\ No newline at end of file\n"
        }
        let suffixContextStart = max(oldChangedEnd, oldEnd - context)
        if suffixContextStart < oldEnd {
            for line in oldLines[suffixContextStart..<oldEnd] { output += " \(line)\n" }
        }
        return output
    }

    private static func lines(_ text: String) -> [String] {
        lineTokens(text).map { token in
            var line = token
            if line.utf8.last == 0x0A { line.removeLast() }
            if line.utf8.last == 0x0D { line.removeLast() }
            return line
        }
    }
}
