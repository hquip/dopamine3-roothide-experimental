import Foundation

enum TestFailure: Error {
    case assertion(String)
}

let files = FileManager.default
let workspace = files.temporaryDirectory.appendingPathComponent("sileo-cache-\(UUID().uuidString)", isDirectory: true)
try files.createDirectory(at: workspace, withIntermediateDirectories: false)
defer { try? files.removeItem(at: workspace) }

func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw TestFailure.assertion(reason) }
}

func rejected(_ operation: () throws -> Void, at expectedPath: URL) throws {
    do {
        try operation()
    } catch let error as TestFailure {
        throw error
    } catch {
        let reportedPath = (error as NSError).userInfo[NSFilePathErrorKey] as? String
        try require(reportedPath == expectedPath.standardizedFileURL.path,
                    "Expected an actionable failure at \(expectedPath.path), got \(String(describing: reportedPath))")
        return
    }
    throw TestFailure.assertion("Expected cache operation to reject \(expectedPath.path)")
}

let primaryRoot = workspace.appendingPathComponent(".jbroot-test", isDirectory: true)
let anchor = primaryRoot.appendingPathComponent("var/lib/apt", isDirectory: true)
let parent = anchor.appendingPathComponent("sileolists", isDirectory: true)
try files.createDirectory(at: parent, withIntermediateDirectories: true)
let owner = (try files.attributesOfItem(atPath: parent.path)[.ownerAccountID] as! NSNumber).uint32Value
let sibling = parent.appendingPathComponent("source_Packages")
let sentinelData = Data("Preserve dependency index\n".utf8)
try sentinelData.write(to: sibling)
var cases: [String] = []

let first = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
try require(first.path == parent.appendingPathComponent("operations").standardizedFileURL.path,
            "Incorrect physical operations path")
try require(first.path.components(separatedBy: ".jbroot-test").count == 2, "Physical prefix was duplicated")
try require(try files.contentsOfDirectory(atPath: first.path).isEmpty, "Fresh operations directory is not empty")
try Data("Package: test\n\n".utf8).write(to: first.appendingPathComponent("source_Packages"))
cases.append("physical parent is used once; metadata is writable")

let second = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
try require(second.path == first.path, "Repeated preparation changed the target")
try require(try files.contentsOfDirectory(atPath: second.path).isEmpty, "Repeated preparation retained stale metadata")
try require(try Data(contentsOf: sibling) == sentinelData, "Repeated preparation removed sibling indexes")
cases.append("repeat clears only operations and preserves sibling indexes")

let outside = workspace.appendingPathComponent("outside", isDirectory: true)
try files.createDirectory(at: outside, withIntermediateDirectories: false)
let outsideSentinel = outside.appendingPathComponent("keep")
try sentinelData.write(to: outsideSentinel)
try files.createDirectory(at: second.appendingPathComponent("nested"), withIntermediateDirectories: false)
try files.createSymbolicLink(at: second.appendingPathComponent("nested/external"), withDestinationURL: outside)
_ = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
try require(try Data(contentsOf: outsideSentinel) == sentinelData, "Stale cleanup followed a contained symbolic link")
cases.append("stale nested directory cleanup does not follow links outside operations")

try files.removeItem(at: first)
try Data("stale regular file".utf8).write(to: first)
_ = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
try require(try files.contentsOfDirectory(atPath: first.path).isEmpty, "Stale regular file was not replaced")
cases.append("stale ordinary file is replaced with an empty directory")

let missingAnchor = primaryRoot.appendingPathComponent("missing-state", isDirectory: true)
try files.createDirectory(at: missingAnchor, withIntermediateDirectories: false)
let missing = missingAnchor.appendingPathComponent("sileolists", isDirectory: true)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: missing, within: missingAnchor, expectedOwnerID: owner)
}, at: missing)
try require(!files.fileExists(atPath: missing.path), "Preparation recreated a missing parent")
cases.append("missing dependency parent fails without recreating indexes")

try files.removeItem(at: first)
try files.createSymbolicLink(at: first, withDestinationURL: outside)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
}, at: first)
try require(try Data(contentsOf: outsideSentinel) == sentinelData, "Rejected operations link changed its destination")
try files.removeItem(at: first)
cases.append("operations symbolic link is rejected and destination preserved")

let linkAnchor = workspace.appendingPathComponent("link-state", isDirectory: true)
let linkDestination = linkAnchor.appendingPathComponent("real-cache", isDirectory: true)
try files.createDirectory(at: linkDestination, withIntermediateDirectories: true)
let linkedSentinel = linkDestination.appendingPathComponent("keep")
try sentinelData.write(to: linkedSentinel)
let parentLink = linkAnchor.appendingPathComponent("sileolists", isDirectory: true)
try files.createSymbolicLink(at: parentLink, withDestinationURL: linkDestination)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: parentLink, within: linkAnchor, expectedOwnerID: owner)
}, at: parentLink)
try require(try Data(contentsOf: linkedSentinel) == sentinelData, "Rejected parent link changed its target")
cases.append("parent symbolic link is rejected")

try rejected({
    _ = try InstallationOperationsCache.prepare(in: outside, within: anchor, expectedOwnerID: owner)
}, at: outside)
try require(!files.fileExists(atPath: outside.appendingPathComponent("operations").path), "Out-of-root target was created")
cases.append("parent outside the exact APT state directory is rejected")

let escapedParent = anchor.appendingPathComponent("outside-ancestor", isDirectory: true)
try files.createSymbolicLink(at: escapedParent, withDestinationURL: outside)
let outsideChild = outside.appendingPathComponent("sileolists", isDirectory: true)
try files.createDirectory(at: outsideChild, withIntermediateDirectories: false)
let escapedChild = escapedParent.appendingPathComponent("sileolists", isDirectory: true)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: escapedChild, within: anchor, expectedOwnerID: owner)
}, at: escapedChild)
try require(!files.fileExists(atPath: outsideChild.appendingPathComponent("operations").path), "Ancestor link escaped cache root")
cases.append("untrusted ancestor link cannot escape the exact APT state parent")

try rejected({
    _ = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner &+ 1)
}, at: parent)
cases.append("unexpected parent owner is rejected")

let alias = workspace.appendingPathComponent("root-alias", isDirectory: true)
try files.createSymbolicLink(at: alias, withDestinationURL: anchor)
let aliasedParent = alias.appendingPathComponent("sileolists", isDirectory: true)
_ = try InstallationOperationsCache.prepare(in: aliasedParent, within: alias, expectedOwnerID: owner)
try require(try files.contentsOfDirectory(atPath: first.path).isEmpty, "Normal root alias did not reach the same cache")
try require(try Data(contentsOf: sibling) == sentinelData, "Normal root alias removed sibling index")
cases.append("ordinary root alias is accepted within the canonical root")

// Model RootHide's legitimate separate AppGroup var storage using real disk
// directories and a var link, rather than pretending Bundle and var share a root.
let bundleRoot = workspace.appendingPathComponent("Bundle/.jbroot-two-tree", isDirectory: true)
let appGroupVar = workspace.appendingPathComponent("AppGroup/.jbroot-two-tree/var", isDirectory: true)
let groupState = appGroupVar.appendingPathComponent("lib/apt", isDirectory: true)
let groupParent = groupState.appendingPathComponent("sileolists", isDirectory: true)
try files.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
try files.createDirectory(at: groupParent, withIntermediateDirectories: true)
try files.createSymbolicLink(at: bundleRoot.appendingPathComponent("var"), withDestinationURL: appGroupVar)
let bundleState = bundleRoot.appendingPathComponent("var/lib/apt", isDirectory: true)
let bundleParent = bundleState.appendingPathComponent("sileolists", isDirectory: true)
let groupSibling = groupParent.appendingPathComponent("source_Packages")
try sentinelData.write(to: groupSibling)
let splitOperations = try InstallationOperationsCache.prepare(in: bundleParent, within: bundleState,
                                                              expectedOwnerID: owner)
try require(splitOperations.resolvingSymlinksInPath().standardizedFileURL.path ==
            groupParent.appendingPathComponent("operations").resolvingSymlinksInPath().standardizedFileURL.path,
            "Separate var storage did not resolve to its legitimate AppGroup operations cache")
try Data("stale split-tree task".utf8).write(to: splitOperations.appendingPathComponent("old-task"))
_ = try InstallationOperationsCache.prepare(in: bundleParent, within: bundleState, expectedOwnerID: owner)
try require(try files.contentsOfDirectory(atPath: splitOperations.path).isEmpty,
            "Repeated preparation did not clear split-tree operations")
try require(try Data(contentsOf: groupSibling) == sentinelData, "Separate var storage lost its sibling index")
cases.append("separate AppGroup var storage is accepted and only operations is rebuilt")

let report: [String: Any] = ["status": "passed", "cases": cases]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
