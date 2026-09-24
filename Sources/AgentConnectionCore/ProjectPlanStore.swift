import CryptoKit
import Darwin
import Foundation

public enum ProjectPlanFormat: String, Codable, Sendable { case short, full }
public enum ProjectPlanStatus: String, Codable, Sendable {
  case draft, approved
  case inProgress = "in_progress"
  case done, abandoned
}
public struct ProjectPlanMetadata: Codable, Equatable, Sendable, Identifiable {
  public let planID: String
  public let title: String
  public let format: ProjectPlanFormat
  public let status: ProjectPlanStatus
  public let revision: Int
  public let path: String
  public let contentHash: String
  public let modifiedAt: Date
  public var id: String { planID }
}
public struct ProjectPlan: Codable, Equatable, Sendable {
  public let metadata: ProjectPlanMetadata
  public let markdown: String
}
public struct ProjectPlanApproval: Codable, Equatable, Sendable {
  public let planID: String
  public let contentHash: String
  public let approvedAt: Date
}
public enum ProjectPlanStoreError: Error, Equatable {
  case invalid, unavailable, stale, notApproved, forbidden
}

public final class ProjectPlanStore {
  private let root: URL
  private let plans: URL
  private let approvalURL: URL
  private let fm = FileManager.default
  public init(projectURL: URL, approvalStoreURL: URL) throws {
    root = projectURL.resolvingSymlinksInPath().standardizedFileURL
    plans = root.appendingPathComponent(".fs/plans", isDirectory: true)
    self.approvalURL = approvalStoreURL
  }
  public convenience init(projectURL: URL, applicationSupportURL: URL? = nil) throws {
    let canonical = projectURL.resolvingSymlinksInPath().standardizedFileURL
    let identity = SHA256.hash(data: Data(canonical.path.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let base =
      applicationSupportURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try self.init(
      projectURL: canonical,
      approvalStoreURL: base.appendingPathComponent("FSCode/plan-approvals/\(identity).json"))
  }
  public func list() throws -> [ProjectPlanMetadata] {
    guard fm.fileExists(atPath: plans.path) else { return [] }
    try safeDirectory(plans)
    return try fm.contentsOfDirectory(
      at: plans, includingPropertiesForKeys: [.contentModificationDateKey], options: []
    ).filter { $0.pathExtension == "md" }.compactMap {
      try? read(planID: $0.deletingPathExtension().lastPathComponent).metadata
    }.sorted { $0.modifiedAt > $1.modifiedAt }
  }
  public func read(planID: String) throws -> ProjectPlan {
    let url = try urlFor(planID)
    var s = stat()
    guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG,
      (s.st_mode & S_IFMT) != S_IFLNK, s.st_size <= 1_048_576,
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { throw ProjectPlanStoreError.unavailable }
    let fields = try frontmatter(text)
    guard fields["plan_id"] == planID,
      let format = ProjectPlanFormat(rawValue: fields["format"] ?? ""),
      let status = ProjectPlanStatus(rawValue: fields["status"] ?? ""),
      let revision = Int(fields["revision"] ?? ""), revision > 0, let title = fields["title"],
      !title.isEmpty
    else { throw ProjectPlanStoreError.invalid }
    return ProjectPlan(
      metadata: .init(
        planID: planID, title: title, format: format, status: status, revision: revision,
        path: ".fs/plans/\(planID).md", contentHash: hash(text),
        modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate) ?? .distantPast), markdown: text)
  }
  public func saveDraft(
    planID: String, title: String, format: ProjectPlanFormat, body: String, expectedRevision: Int?,
    expectedContentHash: String? = nil
  ) throws -> ProjectPlan {
    guard validID(planID), !title.isEmpty, !title.contains("\n"), body.utf8.count <= 900_000 else {
      throw ProjectPlanStoreError.invalid
    }
    let exists = fm.fileExists(atPath: (try urlFor(planID)).path)
    let existing = exists ? try read(planID: planID) : nil
    if let expectedRevision, existing?.metadata.revision != expectedRevision {
      throw ProjectPlanStoreError.stale
    }
    if let expectedContentHash, existing?.metadata.contentHash != expectedContentHash {
      throw ProjectPlanStoreError.stale
    }
    if existing?.metadata.status == .inProgress { throw ProjectPlanStoreError.forbidden }
    let revision = (existing?.metadata.revision ?? 0) + 1
    let existingFields = try existing.map { try frontmatter($0.markdown) }
    let created = existingFields?["created"] ?? ISO8601DateFormatter().string(from: Date()).prefix(10).description
    let baseCommit = existingFields?["base_commit"] ?? "unknown"
    let text =
      "---\nplan_id: \(planID)\ntitle: \(title)\nformat: \(format.rawValue)\nstatus: draft\napproved_via: none\nrevision: \(revision)\ncreated: \(created)\nbase_commit: \(baseCommit)\n---\n\n# \(title)\n\n\(body)"
    try ensurePlans()
    try write(text, to: try urlFor(planID))
    return try read(planID: planID)
  }
  /// Imports the Plan-mode writer's complete document after validating immutable metadata.
  public func importDraft(planID: String, markdown: String) throws -> ProjectPlan {
    guard validID(planID), markdown.utf8.count <= 900_000 else {
      throw ProjectPlanStoreError.invalid
    }
    let fields = try frontmatter(markdown)
    guard fields["plan_id"] == planID,
      let title = fields["title"], !title.isEmpty, !title.contains("\n"),
      ProjectPlanFormat(rawValue: fields["format"] ?? "") != nil,
      fields["status"] == ProjectPlanStatus.draft.rawValue,
      fields["approved_via"] == "none",
      let revision = Int(fields["revision"] ?? ""), revision > 0,
      fields["created"] != nil, fields["base_commit"] != nil
    else { throw ProjectPlanStoreError.invalid }
    let url = try urlFor(planID)
    if fm.fileExists(atPath: url.path) {
      let existing = try read(planID: planID)
      guard existing.metadata.status != .inProgress else { throw ProjectPlanStoreError.forbidden }
      guard revision == existing.metadata.revision + 1 else { throw ProjectPlanStoreError.stale }
    } else if revision != 1 {
      throw ProjectPlanStoreError.stale
    }
    try ensurePlans()
    try write(markdown, to: url)
    return try read(planID: planID)
  }
  public func approve(planID: String) throws -> ProjectPlanApproval {
    let plan = try read(planID: planID)
    guard plan.metadata.status == .draft else { throw ProjectPlanStoreError.forbidden }
    var text = plan.markdown
    text = try replaceFrontmatter(text, key: "status", value: "approved")
    text = try replaceFrontmatter(text, key: "approved_via", value: "editor-action")
    try write(text, to: try urlFor(planID))
    let approved = try read(planID: planID)
    let approval = ProjectPlanApproval(
      planID: planID, contentHash: approved.metadata.contentHash, approvedAt: Date())
    var ledger = try approvals()
    ledger[planID] = approval
    try saveApprovals(ledger)
    return approval
  }
  public func isApproved(planID: String) throws -> Bool {
    let plan = try read(planID: planID)
    return try approvals()[planID]?.contentHash == plan.metadata.contentHash
  }
  public func updateExecution(
    planID: String, expectedRevision: Int, mutation: (inout String) -> Void
  ) throws -> ProjectPlan {
    let plan = try read(planID: planID)
    guard plan.metadata.revision == expectedRevision else { throw ProjectPlanStoreError.stale }
    guard try isApproved(planID: planID) else { throw ProjectPlanStoreError.notApproved }
    var text = plan.markdown
    mutation(&text)
    guard try executionScopeUnchanged(before: plan.markdown, after: text),
      let status = ProjectPlanStatus(rawValue: try frontmatter(text)["status"] ?? ""),
      status == .approved || status == .inProgress || status == .done || status == .abandoned
    else { throw ProjectPlanStoreError.forbidden }
    try write(text, to: try urlFor(planID))
    let updated = try read(planID: planID)
    var ledger = try approvals()
    ledger[planID] = .init(
      planID: planID, contentHash: updated.metadata.contentHash, approvedAt: Date())
    try saveApprovals(ledger)
    return updated
  }
  private func urlFor(_ id: String) throws -> URL {
    guard validID(id) else { throw ProjectPlanStoreError.invalid }
    try ensurePlansSafe()
    return plans.appendingPathComponent(id + ".md")
  }
  private func validID(_ id: String) -> Bool {
    !id.isEmpty && id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
  }
  private func frontmatter(_ text: String) throws -> [String: String] {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
      throw ProjectPlanStoreError.invalid
    }
    var result: [String: String] = [:]
    for line in lines[1..<end] {
      let p = line.split(separator: ":", maxSplits: 1)
      guard p.count == 2 else { throw ProjectPlanStoreError.invalid }
      let key = String(p[0])
      guard result[key] == nil else { throw ProjectPlanStoreError.invalid }
      result[key] = String(p[1]).trimmingCharacters(in: .whitespaces)
    }
    return result
  }
  private func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func safeDirectory(_ url: URL) throws {
    var s = stat()
    guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, (s.st_mode & S_IFMT) != S_IFLNK
    else { throw ProjectPlanStoreError.unavailable }
  }
  private func ensurePlans() throws {
    let meta = root.appendingPathComponent(".fs", isDirectory: true)
    for u in [meta, plans] {
      if fm.fileExists(atPath: u.path) {
        try safeDirectory(u)
      } else {
        try fm.createDirectory(
          at: u, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
    }
  }
  private func ensurePlansSafe() throws {
    let meta = root.appendingPathComponent(".fs", isDirectory: true)
    guard fm.fileExists(atPath: meta.path), fm.fileExists(atPath: plans.path) else { return }
    try safeDirectory(meta)
    try safeDirectory(plans)
  }
  private func write(_ text: String, to url: URL) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".plan-\(UUID().uuidString)")
    try Data(text.utf8).write(to: temp, options: .withoutOverwriting)
    guard rename(temp.path, url.path) == 0 else {
      try? fm.removeItem(at: temp)
      throw ProjectPlanStoreError.unavailable
    }
  }
  private func approvals() throws -> [String: ProjectPlanApproval] {
    guard fm.fileExists(atPath: approvalURL.path) else { return [:] }
    guard let data = try? Data(contentsOf: approvalURL),
      let value = try? JSONDecoder().decode([String: ProjectPlanApproval].self, from: data)
    else { throw ProjectPlanStoreError.unavailable }
    return value
  }
  private func saveApprovals(_ ledger: [String: ProjectPlanApproval]) throws {
    let d = approvalURL.deletingLastPathComponent()
    try fm.createDirectory(
      at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(ledger)
    try data.write(to: approvalURL, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: approvalURL.path)
  }
  private func executionScopeUnchanged(before: String, after: String) throws -> Bool {
    let b = try frontmatter(before)
    let a = try frontmatter(after)
    guard b["plan_id"] == a["plan_id"], b["title"] == a["title"], b["format"] == a["format"],
      b["revision"] == a["revision"]
    else { return false }
    let oldNotes = before.components(separatedBy: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("Build note:")
    }
    let newNotes = after.components(separatedBy: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("Build note:")
    }
    guard newNotes.starts(with: oldNotes) else { return false }
    func normalize(_ s: String) -> String {
      s.components(separatedBy: "\n").filter {
        !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Build note:")
      }.map { line in
        let trim = line.trimmingCharacters(in: .whitespaces)
        if trim.hasPrefix("- Status:") || trim.hasPrefix("status:")
          || trim.hasPrefix("approved_via:")
        {
          return ""
        }
        return line.replacingOccurrences(of: "- [x]", with: "- [ ]").replacingOccurrences(
          of: "- [X]", with: "- [ ]")
      }.joined(separator: "\n")
    }
    return normalize(before) == normalize(after)
  }
  private func replaceFrontmatter(_ text: String, key: String, value: String) throws -> String {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
      throw ProjectPlanStoreError.invalid
    }
    var result = lines
    guard let index = result[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) else {
      throw ProjectPlanStoreError.invalid
    }
    result[index] = key + ": " + value
    return result.joined(separator: "\n")
  }
}
