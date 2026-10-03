// Compiled with the actual app helper extracted from APTWrapper.swift.
// The only spawned command is the ordinary C --probe executable built by CI.

enum PipeTestFailure: Error {
    case assertion(String)
}

func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw PipeTestFailure.assertion(reason) }
}

func openDescriptorCount() -> Int {
    (0..<256).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
}

func normalCase(firstDescriptor: Int32, executable: String) throws -> [String: Any] {
    let initialCount = openDescriptorCount()
    try require(initialCount == 3, "Unexpected inherited descriptor before layout test")
    var reserved: [Int32] = []
    defer { reserved.forEach { close($0) } }
    for expected in 3..<firstDescriptor {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try require(descriptor >= 0, "Unable to reserve ordinary descriptor")
        reserved.append(descriptor)
        try require(descriptor == expected, "Unexpected descriptor reservation layout")
    }

    let io = try InstallationPipeIO.prepare(sileoDescriptor: 6)
    try require(io.descriptors.count == 4, "Expected four real app pipes")
    let layout = io.descriptors
    let owned = layout.flatMap { $0 }
    try require(Set(owned).count == 8, "Relocated descriptors are not unique")
    try require(owned.allSatisfy { $0 >= 7 }, "A source still aliases a child output")
    try require(owned.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }, "Source missing CLOEXEC")
    try require(layout.allSatisfy { fcntl($0[0], F_GETFL) & O_NONBLOCK != 0 }, "Read end is blocking")

    let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("--probe"), nil]
    let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
    defer {
        arguments.forEach { if let pointer = $0 { free(pointer) } }
        environment.forEach { if let pointer = $0 { free(pointer) } }
    }
    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, executable, &io.fileActions, nil, arguments, environment)
    try require(spawnStatus == 0, "Ordinary probe spawn failed: \(spawnStatus)")
    io.closeWriteEnds()
    var reads = layout.map { $0[0] }
    io.releaseReadEnds()
    defer { reads.forEach { close($0) } }
    // Model the consumer taking ownership: later helper teardown must leave
    // all four read descriptors open until their consumers close them.
    io.closeAllDescriptors()
    io.destroyActions()
    try require(reads.allSatisfy { fcntl($0, F_GETFD) != -1 }, "Helper closed transferred read ownership")

    var waitStatus: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(pid, &waitStatus, 0) } while waited == -1 && errno == EINTR
    try require(waited == pid, "Could not wait for ordinary probe")
    try require(waitStatus == 0, "Ordinary child protocol write or descriptor leak failure: \(waitStatus)")
    let payloads = ["stdout-channel\n", "stderr-channel\n", "status-channel\n", "sileo-channel\n"]
    var received: [Bool] = []
    for (index, descriptor) in reads.enumerated() {
        var output = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = read(descriptor, &buffer, 128)
            if count == 0 { break }
            if count == -1 && errno == EINTR { continue }
            try require(count > 0, "Unexpected probe read failure: \(errno)")
            output.append(contentsOf: buffer.prefix(Int(count)))
        }
        let matches = output == Data(payloads[index].utf8)
        try require(matches, "Channel \(index) did not receive its complete payload")
        received.append(matches)
        try require(fcntl(descriptor, F_GETFD) != -1, "Read ownership released before consumer finished")
    }
    reads.forEach { close($0) }
    reads.removeAll()
    io.closeAllDescriptors()
    io.destroyActions()
    io.destroyActions() // Idempotence must not destroy an already-destroyed action object.
    reserved.forEach { close($0) }
    reserved.removeAll()
    let finalCount = openDescriptorCount()
    try require(finalCount == initialCount, "Actual helper leaked a descriptor")
    return ["status": "passed", "case": "actual helper four channels",
            "first_pipe_fd": Int(firstDescriptor), "owned_pipe_fds": layout,
            "channels_received": received, "spawn_status": Int(spawnStatus),
            "initial_open_fds": initialCount, "final_open_fds": finalCount]
}

func failureCase(_ kind: String) throws -> [String: Any] {
    let initialCount = openDescriptorCount()
    try require(initialCount == 3, "Unexpected inherited descriptor before failure test")
    var originalLimit = rlimit()
    try require(getrlimit(RLIMIT_NOFILE, &originalLimit) == 0, "Unable to read process fd limit")
    defer { _ = setrlimit(RLIMIT_NOFILE, &originalLimit) }
    if kind == "pipe-failure" || kind == "relocation-failure" {
        var restrictedLimit = originalLimit
        restrictedLimit.rlim_cur = kind == "pipe-failure" ? 6 : 11
        try require(setrlimit(RLIMIT_NOFILE, &restrictedLimit) == 0, "Unable to restrict this test process")
    }
    let expectedStage = kind == "pipe-failure" ? "create pipe" :
        kind == "relocation-failure" ? "relocate pipe endpoint 0" : "add output duplication"
    let expectedCode = kind == "action-failure" ? EBADF : EMFILE
    let expectedChannel = kind == "pipe-failure" ? "stderr" :
        kind == "relocation-failure" ? "stdout" : "sileo"
    let failure: InstallationPipeSetupError
    do {
        _ = try InstallationPipeIO.prepare(sileoDescriptor: kind == "action-failure" ? -1 : 6)
        throw PipeTestFailure.assertion("Expected actual system call failure in \(kind)")
    } catch let error as InstallationPipeSetupError {
        failure = error
    }
    try require(setrlimit(RLIMIT_NOFILE, &originalLimit) == 0, "Unable to restore this test process fd limit")
    try require(failure.stage == expectedStage, "Incorrect syscall failure stage: \(failure)")
    try require(failure.code == expectedCode, "Incorrect syscall return code: \(failure)")
    try require(failure.channel == expectedChannel, "Incorrect failure channel: \(failure)")
    if kind == "action-failure" {
        try require(failure.actionIndex == 7, "Incorrect failing file-action index")
    }
    let finalCount = openDescriptorCount()
    try require(finalCount == initialCount, "Failure cleanup leaked a descriptor in \(kind)")
    return ["status": "passed", "case": kind, "failed_stage": failure.stage,
            "error_code": Int(failure.code), "diagnostic": failure.description,
            "initial_open_fds": initialCount, "final_open_fds": finalCount]
}

let testArguments = CommandLine.arguments
try require(testArguments.count == 4, "Expected case, fd layout, ordinary probe executable")
let report: [String: Any]
if testArguments[1] == "normal" {
    guard let firstDescriptor = Int32(testArguments[2]) else {
        throw PipeTestFailure.assertion("Invalid layout argument")
    }
    report = try normalCase(firstDescriptor: firstDescriptor, executable: testArguments[3])
} else {
    report = try failureCase(testArguments[1])
}
let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: reportData, as: UTF8.self))
