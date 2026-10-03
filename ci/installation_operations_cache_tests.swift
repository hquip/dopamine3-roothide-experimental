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
        try require(reportedPath == expectedPath.path,
                    "Expected an actionable failure at \(expectedPath.path), got \(String(describing: reportedPath))")
        return
    }
    throw TestFailure.assertion("Expected cache operation to reject \(expectedPath.path)")
}

let anchor = workspace.appendingPathComponent(".jbroot-test", isDirectory: true)
let parent = anchor.appendingPathComponent("var/lib/apt/sileolists", isDirectory: true)
try files.createDirectory(at: parent, withIntermediateDirectories: true)
let owner = (try files.attributesOfItem(atPath: parent.path)[.ownerAccountID] as! NSNumber).uint32Value
let sibling = parent.appendingPathComponent("source_Packages")
let sentinelData = Data("Preserve dependency index\n".utf8)
try sentinelData.write(to: sibling)
var cases: [String] = []

let first = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner)
try require(first.path == parent.appendingPathComponent("operations").path, "Incorrect physical operations path")
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

let missing = anchor.appendingPathComponent("missing-parent", isDirectory: true)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: missing, within: anchor, expectedOwnerID: owner)
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

let parentLink = anchor.appendingPathComponent("parent-link", isDirectory: true)
try files.createSymbolicLink(at: parentLink, withDestinationURL: parent)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: parentLink, within: anchor, expectedOwnerID: owner)
}, at: parentLink)
try require(try Data(contentsOf: sibling) == sentinelData, "Rejected parent link changed its target")
cases.append("parent symbolic link is rejected")

try rejected({
    _ = try InstallationOperationsCache.prepare(in: outside, within: anchor, expectedOwnerID: owner)
}, at: outside)
try require(!files.fileExists(atPath: outside.appendingPathComponent("operations").path), "Out-of-root target was created")
cases.append("canonical parent outside cache root is rejected")

let escapedParent = anchor.appendingPathComponent("outside-ancestor", isDirectory: true)
try files.createSymbolicLink(at: escapedParent, withDestinationURL: outside)
let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
try files.createDirectory(at: outsideChild, withIntermediateDirectories: false)
let escapedChild = escapedParent.appendingPathComponent("child", isDirectory: true)
try rejected({
    _ = try InstallationOperationsCache.prepare(in: escapedChild, within: anchor, expectedOwnerID: owner)
}, at: escapedChild)
try require(!files.fileExists(atPath: outsideChild.appendingPathComponent("operations").path), "Ancestor link escaped cache root")
cases.append("ancestor symbolic link cannot escape canonical cache root")

try rejected({
    _ = try InstallationOperationsCache.prepare(in: parent, within: anchor, expectedOwnerID: owner &+ 1)
}, at: parent)
cases.append("unexpected parent owner is rejected")

let alias = workspace.appendingPathComponent("root-alias", isDirectory: true)
try files.createSymbolicLink(at: alias, withDestinationURL: anchor)
let aliasedParent = alias.appendingPathComponent("var/lib/apt/sileolists", isDirectory: true)
_ = try InstallationOperationsCache.prepare(in: aliasedParent, within: anchor, expectedOwnerID: owner)
try require(try files.contentsOfDirectory(atPath: first.path).isEmpty, "Normal root alias did not reach the same cache")
try require(try Data(contentsOf: sibling) == sentinelData, "Normal root alias removed sibling index")
cases.append("ordinary root alias is accepted within the canonical root")

let report: [String: Any] = ["status": "passed", "cases": cases]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
