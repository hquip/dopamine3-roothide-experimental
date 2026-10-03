//
//  DependencyResolverAccelerator.swift
//  Sileo
//
//  Created by CoolStar on 1/19/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import Evander

// BEGIN INSTALLATION OPERATIONS CACHE HELPER
// This is also compiled by the Foundation-only filesystem regression test.
enum InstallationOperationsCache {
    static func prepare(in parent: URL, within cacheRoot: URL,
                        expectedOwnerID: UInt32? = nil,
                        fileManager: FileManager = .default) throws -> URL {
        let parent = parent.standardizedFileURL
        let operations = parent.appendingPathComponent("operations", isDirectory: true).standardizedFileURL

        func reject(_ path: URL, _ reason: String) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue,
                    userInfo: [NSFilePathErrorKey: path.path, NSLocalizedDescriptionKey: reason])
        }

        guard parent.isFileURL, cacheRoot.isFileURL,
              operations.deletingLastPathComponent().path == parent.path else {
            throw reject(operations, "Installation metadata must be a direct cache child.")
        }
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let canonicalRoot = cacheRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard canonicalParent.starts(with: canonicalRoot) else {
            throw reject(parent, "Installation metadata is outside the package cache root.")
        }

        // Require the existing, writable parent; never recreate or change ownership
        // of the dependency indexes here. attributesOfItem inspects the link itself.
        let parentAttributes = try fileManager.attributesOfItem(atPath: parent.path)
        guard parentAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw reject(parent, "Installation metadata parent must be a directory, not a symbolic link.")
        }
        if let expectedOwnerID = expectedOwnerID,
           (parentAttributes[.ownerAccountID] as? NSNumber)?.uint32Value != expectedOwnerID {
            throw reject(parent, "Installation metadata parent is not owned by the current app user.")
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw reject(parent, "Installation metadata parent is not writable by the current app user.")
        }

        let existingAttributes: [FileAttributeKey: Any]?
        do {
            existingAttributes = try fileManager.attributesOfItem(atPath: operations.path)
        } catch {
            let fileError = error as NSError
            guard fileError.domain == NSCocoaErrorDomain,
                  fileError.code == CocoaError.Code.fileReadNoSuchFile.rawValue else { throw error }
            existingAttributes = nil
        }
        if let attributes = existingAttributes {
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw reject(operations, "Installation metadata cannot replace a symbolic link or special file.")
            }
            // FileManager removes contained symbolic links, not their destinations.
            // Only this precise operations child is removed; sibling indexes survive.
            try fileManager.removeItem(at: operations)
        }
        try fileManager.createDirectory(at: operations, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o755])
        return operations
    }
}
// END INSTALLATION OPERATIONS CACHE HELPER

class DependencyResolverAccelerator {
    public static let shared = DependencyResolverAccelerator()
    
    struct PreflightedPackage: PackageProtocol {

        let version: String
        let package: String
        let data: Data
        
        init(package: Package) {
            self.version = package.version
            self.package = package.package
            self.data = package.rawData ?? Data()
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(package)
            hasher.combine(version)
        }
    }
    
    private var preflightedPackages: [URL: Set<PreflightedPackage>] = [:]
    private var toBePreflighted: [URL: Set<PreflightedPackage>] = [:]
    private var preflightLock = NSRecursiveLock()
    public func preflightInstalled() {
        NSLog("SileoLog: DependencyResolverAccelerator.preflightInstalled()")
        if Thread.isMainThread {
            fatalError("Don't call things that will block the UI from the main thread")
        }
       
        preflightLock.lock()
        try? getDependencies(packages: Array(PackageListManager.shared.installedPackages.values))
        preflightLock.unlock()
    }
    
    private var depResolverPrefix: URL = {
        #if targetEnvironment(simulator) || TARGET_SANDBOX
        let listsURL = FileManager.default.documentDirectory.appendingPathComponent("sileolists")
        if !listsURL.dirExists {
            try? FileManager.default.createDirectory(at: listsURL, withIntermediateDirectories: true)
        }
        return listsURL
        #else
        return URL(fileURLWithPath: CommandPath.sileolists)
        #endif
    }()
    
    init() {
        #if targetEnvironment(simulator) || TARGET_SANDBOX
        try? FileManager.default.removeItem(atPath: CommandPath.sileolists)
        #else
        spawnAsRoot(args: [CommandPath.rm, "-rf", rootfs(CommandPath.sileolists)])
        spawnAsRoot(args: [CommandPath.mkdir, "-p", rootfs(CommandPath.sileolists)])
        spawnAsRoot(args: [CommandPath.chown, "-R", CommandPath.group, rootfs(CommandPath.sileolists)])
        spawnAsRoot(args: [CommandPath.chmod, "-R", "0755", rootfs(CommandPath.sileolists)])
        #endif
    }
    
    public func removeRepo(repo: Repo) {
        NSLog("SileoLog: DependencyResolverAccelerator.removeRepo(\(repo.url)")
        if !repo.archAvailabile {
            return
        }
        
        self.preflightLock.lock()
        defer { self.preflightLock.unlock() }
        
        let url = RepoManager.shared.cacheFile(named: "Packages", for: repo)
        let newSourcesFile = depResolverPrefix.appendingPathComponent(url.lastPathComponent)
        toBePreflighted.removeValue(forKey: url)
        preflightedPackages.removeValue(forKey: url)
        #if targetEnvironment(simulator) || TARGET_SANDBOX
        try? FileManager.default.removeItem(at: newSourcesFile)
        #else
        spawnAsRoot(args: [CommandPath.rm, "-rf", rootfs(newSourcesFile.path)])
        #endif
    }
    
    public func buildOperations(packages: [Package]) throws {
        preflightLock.lock()
        defer { preflightLock.unlock() }

        #if targetEnvironment(simulator) || TARGET_SANDBOX
        let cacheRoot = FileManager.default.documentDirectory
        let expectedOwnerID: UInt32? = nil
        #elseif targetEnvironment(macCatalyst)
        let cacheRoot = URL(fileURLWithPath: CommandPath.prefix)
        let expectedOwnerID: UInt32? = nil
        #else
        let cacheRoot = URL(fileURLWithPath: CommandPath.prefix.isEmpty ? "/" : CommandPath.prefix)
        let expectedOwnerID: UInt32? = 501
        #endif
        // depResolverPrefix is already physical on RootHide, exactly as it is in
        // getDependencies. Mapping it through jbroot again duplicates the prefix.
        let resolverPrefix = try InstallationOperationsCache.prepare(
            in: depResolverPrefix, within: cacheRoot, expectedOwnerID: expectedOwnerID)
        
        for package in packages {
            //NSLog("SileoLog: sourcesFile=\(sourcesFile) packages=\(packages.map({ $0.package }))")
            
            guard let data=package.rawData, let sourceFile=package.sourceFileURL else { continue }
            
            let newSourcesFile = resolverPrefix.appendingPathComponent(sourceFile.lastPathComponent)
            
            var sourcesData = Data()
            var bytes = [UInt8](data)
            if bytes.suffix(2) != [10, 10] { // \n\n
                if bytes.last == 10 {
                    bytes.append(10)
                } else {
                    bytes.append(contentsOf: [10, 10])
                }
            }
            sourcesData.append(Data(bytes))
            try sourcesData.append(to: newSourcesFile)
        }
    }
    
    public func getDependencies(packages: [Package]) throws {
        NSLog("SileoLog: DependencyResolverAccelerator.getDependencies(\(packages.map({ $0.package }))")
        NSLog("SileoLog: preflightedPackages=\(preflightedPackages.keys)")
        NSLog("SileoLog: toBePreflighted=\(toBePreflighted.keys))")
        if Thread.isMainThread {
            fatalError("Don't call things that will block the UI from the main thread")
        }
        PackageListManager.shared.initWait()
        NSLog("SileoLog: getDependencies2")
        
        self.preflightLock.lock()
        defer { self.preflightLock.unlock() }

        for package in packages {
            getDependenciesInternal(package: package)
        }
        NSLog("SileoLog: getDependencies3 toBePreflighted=\(toBePreflighted.keys))")
        
        let resolverPrefix = depResolverPrefix
        for (sourcesFile, packages) in toBePreflighted {
            //NSLog("SileoLog: sourcesFile=\(sourcesFile) packages=\(packages.map({ $0.package }))")
            
            defer { toBePreflighted.removeValue(forKey: sourcesFile) }
            
            if sourcesFile.lastPathComponent == "status" || sourcesFile.scheme == "local" {
                continue
            }
            let newSourcesFile = resolverPrefix.appendingPathComponent(sourcesFile.lastPathComponent)
            
            var sourcesData = Data()
            for package in packages {
                var bytes = [UInt8](package.data)
                if bytes.suffix(2) != [10, 10] { // \n\n
                    if bytes.last == 10 {
                        bytes.append(10)
                    } else {
                        bytes.append(contentsOf: [10, 10])
                    }
                }
                sourcesData.append(Data(bytes))
            }
            do {
                try sourcesData.append(to: newSourcesFile)
            } catch {
                NSLog("SileoLog: throw \(error)")
                throw error
            }
            
            let preflighted = preflightedPackages[sourcesFile] ?? Set<PreflightedPackage>()
            preflightedPackages[sourcesFile] = preflighted.union(packages)
        }
        NSLog("SileoLog: getDependencies4")
    }
    
    private func getDependenciesInternal(package: Package) {
        //NSLog("SileoLog: getDependenciesInternal \(package.package) \(package.sourceFileURL)")
        let url = package.sourceFileURL ?? URL(string: "local://")!
        if let preflighted = preflightedPackages[url] {
            if preflighted.contains(where: { $0 == package }) {
                return
            }
        }
        for packageVersion in package.allVersions() {
            getDependenciesInternal2(package: packageVersion, sourceFileURL: url)
        }
    }
   
    private func getDependenciesInternal2(package: Package, sourceFileURL: URL) {
        //NSLog("SileoLog: getDependenciesInternal2 \(package.package) \(sourceFileURL)")
        if let preflighted = toBePreflighted[sourceFileURL] {
            if preflighted.contains(where: { $0 == package }) {
                return
            }
        } else {
            toBePreflighted[sourceFileURL] = Set<PreflightedPackage>()
        }
        toBePreflighted[sourceFileURL]?.insert(PreflightedPackage(package: package))
        
        //also resolve the installed package itself
        //,but this doesn't make sense due the package is in an inconsistent state and dpkg cannot uninstall it
//        for repo in RepoManager.shared.repoList {
//            if let thePackage = repo.newestPackage(identifier: package.package) {
//                getDependenciesInternal(package: thePackage)
//            }
//        }
  
        // Depends, Pre-Depends, Recommends, Suggests, Breaks, Conflicts, Provides, Replaces, Enhance
        let packageKeys = ["depends", "pre-depends", "conflicts", "replaces", "recommends", "provides", "breaks"]
        for packageKey in packageKeys {
            if let packagesData = package.rawControl[packageKey] {
                let packageIds = parseDependsString(depends: packagesData)
                for repo in RepoManager.shared.repoList {
                    for packageID in packageIds {
                        if let depPackage = repo.newestPackage(identifier: packageID) {
                            getDependenciesInternal(package: depPackage)
                        }
                    }
                    
                    for depPackage in repo.packagesProvides {
                        for packageId in packageIds {
                            if depPackage.rawControl["provides"]?.contains(packageId) ?? false {
                                getDependenciesInternal(package: depPackage)
                                break
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func parseDependsString(depends: String) -> [String] {
        let parts = depends.components(separatedBy: CharacterSet(charactersIn: ",|"))
        var packageIds: [String] = []
        for part in parts {
            let newPart = part.replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression).replacingOccurrences(of: " ", with: "")
            packageIds.append(newPart)
        }
        return packageIds
    }
    
}
