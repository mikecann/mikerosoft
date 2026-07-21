import Foundation
import XCTest
@testable import TaskbarApp

final class TaskbarStatsSamplerTests: XCTestCase {
    func testSamplerAcquiresOneMachHostPortAndReleasesItOnDeinit() {
        var acquisitionCount = 0
        var releasedPorts: [host_t] = []

        do {
            let sampler = TaskbarStatsSampler(
                commandOutput: { _, _ in nil },
                cpuTickReader: { nil },
                memoryReader: { nil },
                hostPortProvider: {
                    acquisitionCount += 1
                    return host_t(42)
                },
                hostPortReleaser: { releasedPorts.append($0) }
            )

            _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
            _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))
            XCTAssertEqual(acquisitionCount, 1)
            XCTAssertTrue(releasedPorts.isEmpty)
        }

        XCTAssertEqual(acquisitionCount, 1)
        XCTAssertEqual(releasedPorts, [host_t(42)])
    }

    func testSamplerDoesNotRunSubprocessesWithoutDemand() {
        let queue = DispatchQueue(label: "TaskbarStatsSamplerTests.noDemand")
        var executables: [String] = []
        let sampler = TaskbarStatsSampler(
            commandOutput: { executable, _ in
                executables.append(executable)
                return nil
            },
            backgroundQueue: queue,
            cpuTickReader: { nil },
            memoryReader: { nil },
            networkCounterReader: { nil }
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000), demand: [])
        queue.sync {}

        XCTAssertTrue(executables.isEmpty)
    }

    func testSamplingDemandMatchesVisibleTilesAndPopoverDetails() {
        var settings = StatsWidgetSettings.defaults
        settings.showCPU = true
        settings.showGPU = false
        settings.showMemory = false
        settings.showNetwork = false
        XCTAssertEqual(StatsSamplingDemand.visibleMetrics(settings), [])

        settings.showGPU = true
        XCTAssertEqual(StatsSamplingDemand.visibleMetrics(settings), [.gpu])

        settings.isEnabled = false
        XCTAssertEqual(StatsSamplingDemand.visibleMetrics(settings), [])
        XCTAssertEqual(StatsSamplingDemand.popover(.cpu), [.processes])
        XCTAssertEqual(StatsSamplingDemand.popover(.memory), [.processes])
        XCTAssertEqual(StatsSamplingDemand.popover(.gpu), [.gpu])
        XCTAssertEqual(StatsSamplingDemand.popover(.network), [.networkProcesses])
        XCTAssertEqual(StatsSamplingDemand.menuSummary, [.gpu])
    }

    func testSamplerRunsOnlyTheRequestedSubprocess() {
        let scenarios: [(demand: StatsSamplingDemand, executable: String)] = [
            ([.gpu], "/usr/sbin/ioreg"),
            ([.processes], "/bin/ps"),
            ([.networkProcesses], "/usr/bin/nettop")
        ]

        for (index, scenario) in scenarios.enumerated() {
            let queue = DispatchQueue(label: "TaskbarStatsSamplerTests.demand.\(index)")
            var executables: [String] = []
            let sampler = TaskbarStatsSampler(
                commandOutput: { executable, _ in
                    executables.append(executable)
                    return nil
                },
                backgroundQueue: queue,
                cpuTickReader: { nil },
                memoryReader: { nil },
                networkCounterReader: { nil }
            )

            _ = sampler.snapshot(
                now: Date(timeIntervalSince1970: 1_000),
                demand: scenario.demand
            )
            queue.sync {}

            XCTAssertEqual(executables, [scenario.executable])
        }
    }

    func testNewPopoverDemandIsNotBlockedByFreshSnapshotCache() {
        let queue = DispatchQueue(label: "TaskbarStatsSamplerTests.freshSnapshotDemand")
        var executables: [String] = []
        let sampler = TaskbarStatsSampler(
            commandOutput: { executable, _ in
                executables.append(executable)
                return nil
            },
            backgroundQueue: queue,
            cpuTickReader: { nil },
            memoryReader: { nil },
            networkCounterReader: { nil }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = sampler.snapshot(now: start, demand: [])
        _ = sampler.snapshot(
            now: start.addingTimeInterval(0.1),
            demand: StatsSamplingDemand.popover(.network)
        )
        queue.sync {}

        XCTAssertEqual(executables, ["/usr/bin/nettop"])
    }

    func testNetworkTransferRatesUseSteadyPerInterfaceCounterDeltas() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 1_000, download: 2_000)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 1_300, download: 2_600)
            ],
            elapsed: 2
        )

        XCTAssertEqual(rates.upload, 150, accuracy: 0.001)
        XCTAssertEqual(rates.download, 300, accuracy: 0.001)
    }

    func testNetworkTransferRatesIgnoreAnInterfaceThatDisappears() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 9_000, download: 12_000),
                "en1": NetworkInterfaceCounters(upload: 500, download: 800)
            ],
            current: [
                "en1": NetworkInterfaceCounters(upload: 650, download: 1_100)
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates.upload, 150, accuracy: 0.001)
        XCTAssertEqual(rates.download, 300, accuracy: 0.001)
    }

    func testNetworkTransferRatesGiveNewOrReappearedInterfacesAZeroFirstSample() {
        let rates = networkTransferRates(
            previous: [:],
            current: [
                "en0": NetworkInterfaceCounters(upload: 8_000_000_000, download: 12_000_000_000)
            ],
            elapsed: 0.75
        )

        XCTAssertEqual(rates, .zero)
    }

    func testNetworkTransferRatesAggregateOnlyComparableInterfacesInAMixedSample() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 1_000, download: 2_000),
                "gone": NetworkInterfaceCounters(upload: 900_000, download: 800_000)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 1_150, download: 2_300),
                "new": NetworkInterfaceCounters(upload: 5_000_000, download: 9_000_000)
            ],
            elapsed: 0.75
        )

        XCTAssertEqual(rates.upload, 200, accuracy: 0.001)
        XCTAssertEqual(rates.download, 400, accuracy: 0.001)
    }

    func testNetworkTransferRatesRecoverA32BitCounterWrap() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(
                    upload: UInt64(UInt32.max) - 100,
                    download: UInt64(UInt32.max) - 300,
                    width: .bits32
                )
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 49, download: 99, width: .bits32)
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates.upload, 150, accuracy: 0.001)
        XCTAssertEqual(rates.download, 400, accuracy: 0.001)
    }

    func testNetworkTransferRatesDoNotWrapAcrossCounterWidthChanges() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(
                    upload: UInt64(UInt32.max) - 100,
                    download: UInt64(UInt32.max) - 100,
                    width: .bits32
                )
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 49, download: 49, width: .bits64)
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates, .zero)
    }

    func testNetworkTransferRatesRejectASmall64BitCounterReset() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 1_000, download: 2_000)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 999, download: 1_999)
            ],
            elapsed: 0.75
        )

        XCTAssertEqual(rates, .zero)
    }

    func testNetworkTransferRatesRejectA64BitCounterResetBefore4GiB() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 2_200_000_000, download: 2_200_000_000)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 0, download: 0)
            ],
            elapsed: 0.75
        )

        XCTAssertEqual(rates, .zero)
    }

    func testNetworkTransferRatesRejectA64BitCounterRegression() {
        let over32Bits = UInt64(UInt32.max) + 10_000
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: over32Bits, download: over32Bits + 100)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: 49, download: over32Bits + 50)
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates, .zero)
    }

    func testNetworkTransferRatesReturnZeroWithoutAPositiveElapsedInterval() {
        let previous = [
            "en0": NetworkInterfaceCounters(upload: 100, download: 200)
        ]
        let current = [
            "en0": NetworkInterfaceCounters(upload: 150, download: 300)
        ]

        XCTAssertEqual(
            networkTransferRates(previous: previous, current: current, elapsed: 0),
            .zero
        )
        XCTAssertEqual(
            networkTransferRates(previous: previous, current: current, elapsed: -1),
            .zero
        )
    }

    func testNetworkTransferRatesDiscardValuesAbove100GigabitsPerSecond() {
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 0, download: 0)
            ],
            current: [
                "en0": NetworkInterfaceCounters(
                    upload: maximumPlausibleNetworkBytesPerSecond + 1,
                    download: maximumPlausibleNetworkBytesPerSecond
                )
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates.upload, 0)
        XCTAssertEqual(rates.download, Double(maximumPlausibleNetworkBytesPerSecond), accuracy: 0.001)
    }

    func testNetworkTransferRatesDiscardAnAggregateAbove100GigabitsPerSecond() {
        let perInterfaceDelta = maximumPlausibleNetworkBytesPerSecond / 2 + 1
        let rates = networkTransferRates(
            previous: [
                "en0": NetworkInterfaceCounters(upload: 0, download: 0),
                "en1": NetworkInterfaceCounters(upload: 0, download: 0)
            ],
            current: [
                "en0": NetworkInterfaceCounters(upload: perInterfaceDelta, download: perInterfaceDelta),
                "en1": NetworkInterfaceCounters(upload: perInterfaceDelta, download: perInterfaceDelta)
            ],
            elapsed: 1
        )

        XCTAssertEqual(rates, .zero)
    }

    func testPerInterface64BitAggregationMatchesLegacyGlobalMathBefore32BitWrap() {
        let previous = [
            "en0": NetworkInterfaceCounters(upload: 1_000, download: 2_000),
            "en1": NetworkInterfaceCounters(upload: 3_000, download: 4_000)
        ]
        let current = [
            "en0": NetworkInterfaceCounters(upload: 1_150, download: 2_300),
            "en1": NetworkInterfaceCounters(upload: 3_225, download: 4_450)
        ]
        let elapsed = 0.75

        let rates = networkTransferRates(previous: previous, current: current, elapsed: elapsed)
        let legacyUpload = Double(
            current.values.reduce(UInt64(0)) { $0 + $1.upload }
                - previous.values.reduce(UInt64(0)) { $0 + $1.upload }
        ) / elapsed
        let legacyDownload = Double(
            current.values.reduce(UInt64(0)) { $0 + $1.download }
                - previous.values.reduce(UInt64(0)) { $0 + $1.download }
        ) / elapsed

        XCTAssertEqual(rates.upload, legacyUpload, accuracy: 0.001)
        XCTAssertEqual(rates.download, legacyDownload, accuracy: 0.001)
    }

    func testSamplerReplacesInterfaceStateAcrossAFlapAndKeepsTheArtifactOutOfHistory() {
        var readings: [[String: NetworkInterfaceCounters]?] = [
            ["en0": NetworkInterfaceCounters(upload: 1_000, download: 2_000)],
            ["en0": NetworkInterfaceCounters(upload: 1_100, download: 2_200)],
            [:],
            ["en0": NetworkInterfaceCounters(upload: 9_000_000_000, download: 12_000_000_000)],
            ["en0": NetworkInterfaceCounters(upload: 9_000_000_075, download: 12_000_000_150)]
        ]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.network"),
            cpuTickReader: { nil },
            memoryReader: { nil },
            networkCounterReader: { readings.removeFirst() }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = sampler.snapshot(now: start)
        let moving = sampler.snapshot(now: start.addingTimeInterval(1))
        let disappeared = sampler.snapshot(now: start.addingTimeInterval(2))
        let reappeared = sampler.snapshot(now: start.addingTimeInterval(3))
        let resumed = sampler.snapshot(now: start.addingTimeInterval(4))

        XCTAssertEqual(moving.networkUploadBytesPerSecond, 100, accuracy: 0.001)
        XCTAssertEqual(moving.networkDownloadBytesPerSecond, 200, accuracy: 0.001)
        XCTAssertEqual(disappeared.networkUploadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(disappeared.networkDownloadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(reappeared.networkUploadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(reappeared.networkDownloadBytesPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(reappeared.networkUploadHistory.max(), 100)
        XCTAssertEqual(reappeared.networkDownloadHistory.max(), 200)
        XCTAssertEqual(resumed.networkUploadBytesPerSecond, 75, accuracy: 0.001)
        XCTAssertEqual(resumed.networkDownloadBytesPerSecond, 150, accuracy: 0.001)
    }

    func testSamplerStoresZeroInsteadOfAnImplausibleRateArtifact() {
        var readings: [[String: NetworkInterfaceCounters]?] = [
            ["en0": NetworkInterfaceCounters(upload: 10, download: 20)],
            [
                "en0": NetworkInterfaceCounters(
                    upload: 11 + maximumPlausibleNetworkBytesPerSecond,
                    download: 21 + maximumPlausibleNetworkBytesPerSecond
                )
            ]
        ]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.networkArtifact"),
            cpuTickReader: { nil },
            memoryReader: { nil },
            networkCounterReader: { readings.removeFirst() }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        _ = sampler.snapshot(now: start)
        let snapshot = sampler.snapshot(now: start.addingTimeInterval(1))

        XCTAssertEqual(snapshot.networkUploadBytesPerSecond, 0)
        XCTAssertEqual(snapshot.networkDownloadBytesPerSecond, 0)
        XCTAssertEqual(snapshot.networkUploadHistory.max(), 0)
        XCTAssertEqual(snapshot.networkDownloadHistory.max(), 0)
    }

    func testStatsSnapshotEqualityIncludesMeasuredBreakdowns() {
        var changed = StatsSnapshot.empty
        changed.cpuUserPercent = 1
        XCTAssertNotEqual(changed, .empty)

        changed = .empty
        changed.memoryCompressedBytes = 1
        XCTAssertNotEqual(changed, .empty)
    }

    func testCPUUsageSplitsRealTickDeltasAndFoldsNiceIntoUser() throws {
        let usage = try XCTUnwrap(
            cpuUsage(
                currentTicks: [130, 220, 350, 410],
                previousTicks: [100, 200, 300, 400]
            )
        )

        XCTAssertEqual(usage.userPercent, 40.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.systemPercent, 20.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.idlePercent, 50.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.activePercent, 60.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.userPercent + usage.systemPercent, usage.activePercent, accuracy: 0.001)
    }

    func testCPUUsageRejectsSamplesWithoutAnInterval() {
        let ticks: [UInt32] = [100, 200, 300, 400]

        XCTAssertNil(cpuUsage(currentTicks: ticks, previousTicks: nil))
        XCTAssertNil(cpuUsage(currentTicks: ticks, previousTicks: ticks))
    }

    func testCPUProcessorPercentsPublishOneCurrentValuePerLogicalCPU() throws {
        let percents = try XCTUnwrap(
            cpuProcessorPercents(
                currentTicks: [
                    [130, 220, 350, 410],
                    [110, 210, 360, 420]
                ],
                previousTicks: [
                    [100, 200, 300, 400],
                    [100, 200, 300, 400]
                ]
            )
        )

        XCTAssertEqual(percents.count, 2)
        XCTAssertEqual(percents[0], 60.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(percents[1], 40, accuracy: 0.001)
    }

    func testCPUProcessorPercentsRejectMismatchedProcessorSamples() {
        XCTAssertNil(
            cpuProcessorPercents(
                currentTicks: [[100, 200, 300, 400]],
                previousTicks: [
                    [100, 200, 300, 400],
                    [100, 200, 300, 400]
                ]
            )
        )
    }

    func testCPUPerformanceLevelsReadSystemNamesAndCountsInPerformanceOrder() {
        let integers = [
            "hw.nperflevels": 2,
            "hw.perflevel0.logicalcpu": 6,
            "hw.perflevel1.logicalcpu": 12
        ]
        let strings = [
            "hw.perflevel0.name": "Super",
            "hw.perflevel1.name": "Performance"
        ]

        let levels = cpuPerformanceLevels(
            integerReader: { integers[$0] },
            stringReader: { strings[$0] }
        )

        XCTAssertEqual(
            levels,
            [
                CPUPerformanceLevel(name: "Super", processorCount: 6),
                CPUPerformanceLevel(name: "Performance", processorCount: 12)
            ]
        )
    }

    func testCPUPerformanceLevelsRejectIncompleteTopology() {
        let levels = cpuPerformanceLevels(
            integerReader: { name in
                [
                    "hw.nperflevels": 2,
                    "hw.perflevel0.logicalcpu": 6
                ][name]
            },
            stringReader: { _ in nil }
        )

        XCTAssertTrue(levels.isEmpty)
    }

    func testProcessorLevelIndicesReversePerformanceLevelsToMatchLogicalCPUOrder() {
        let levels = [
            CPUPerformanceLevel(name: "Super", processorCount: 2),
            CPUPerformanceLevel(name: "Performance", processorCount: 4)
        ]

        XCTAssertEqual(
            cpuProcessorPerformanceLevelIndices(levels: levels, processorCount: 6),
            [1, 1, 1, 1, 0, 0]
        )
        XCTAssertEqual(
            cpuProcessorPerformanceLevelIndices(levels: levels, processorCount: 5),
            [nil, nil, nil, nil, nil]
        )
    }

    func testCPUPerformanceColourRolesUseReportedLevelNames() {
        XCTAssertEqual(
            cpuPerformanceColorRole(
                for: CPUPerformanceLevel(name: "Super", processorCount: 6),
                index: 0,
                totalLevels: 2
            ),
            .superCore
        )
        XCTAssertEqual(
            cpuPerformanceColorRole(
                for: CPUPerformanceLevel(name: "Performance", processorCount: 12),
                index: 1,
                totalLevels: 2
            ),
            .performance
        )
        XCTAssertEqual(
            cpuPerformanceColorRole(
                for: CPUPerformanceLevel(name: "Efficiency", processorCount: 4),
                index: 1,
                totalLevels: 2
            ),
            .efficiency
        )
    }

    func testSnapshotPublishesAndPreservesRealCPUSplit() {
        var readings: [[UInt32]?] = [
            [100, 200, 300, 400],
            [140, 220, 330, 410],
            nil
        ]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.cpu"),
            cpuTickReader: { readings.removeFirst() }
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        let measured = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))
        let cached = sampler.snapshot(now: Date(timeIntervalSince1970: 1_002))

        XCTAssertEqual(measured.cpuPercent, 70, accuracy: 0.001)
        XCTAssertEqual(measured.cpuUserPercent, 50, accuracy: 0.001)
        XCTAssertEqual(measured.cpuSystemPercent, 20, accuracy: 0.001)
        XCTAssertEqual(cached.cpuPercent, measured.cpuPercent, accuracy: 0.001)
        XCTAssertEqual(cached.cpuUserPercent, measured.cpuUserPercent, accuracy: 0.001)
        XCTAssertEqual(cached.cpuSystemPercent, measured.cpuSystemPercent, accuracy: 0.001)
    }

    func testSnapshotPublishesAndPreservesPerProcessorCPUUtilisation() {
        var processorReadings: [[[UInt32]]?] = [
            [
                [100, 200, 300, 400],
                [100, 200, 300, 400]
            ],
            [
                [130, 220, 350, 410],
                [110, 210, 360, 420]
            ],
            nil
        ]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.cpuProcessors"),
            cpuTickReader: { nil },
            cpuProcessorTickReader: { processorReadings.removeFirst() },
            cpuPerformanceLevelReader: {
                [
                    CPUPerformanceLevel(name: "Performance", processorCount: 1),
                    CPUPerformanceLevel(name: "Efficiency", processorCount: 1)
                ]
            }
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        let measured = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))
        let cached = sampler.snapshot(now: Date(timeIntervalSince1970: 1_002))

        XCTAssertEqual(measured.cpuProcessorPercents.count, 2)
        XCTAssertEqual(measured.cpuProcessorPercents[0], 60.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(measured.cpuProcessorPercents[1], 40, accuracy: 0.001)
        XCTAssertEqual(cached.cpuProcessorPercents, measured.cpuProcessorPercents)
        XCTAssertEqual(measured.cpuProcessorPerformanceLevelIndices, [1, 0])
        XCTAssertEqual(measured.cpuPerformanceLevels.map(\.name), ["Performance", "Efficiency"])
    }

    func testMemoryBreakdownUsesMeasuredComponentsAndAccountsForUsedBytes() {
        let breakdown = memoryBreakdown(
            usedBytes: 16_000,
            wiredBytes: 3_000,
            compressedBytes: 2_000
        )

        XCTAssertEqual(breakdown.appBytes, 11_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.wiredBytes, 3_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.compressedBytes, 2_000, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(breakdown.appBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.wiredBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.compressedBytes, 0)
        XCTAssertEqual(
            breakdown.appBytes + breakdown.wiredBytes + breakdown.compressedBytes,
            16_000,
            accuracy: 0.001
        )
    }

    func testMemoryBreakdownClampsOnlyAppAndPreservesMeasuredComponents() {
        let breakdown = memoryBreakdown(
            usedBytes: 10_000,
            wiredBytes: 8_000,
            compressedBytes: 4_000
        )

        XCTAssertEqual(breakdown.appBytes, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.wiredBytes, 8_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.compressedBytes, 4_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.usedBytes, 12_000, accuracy: 0.001)
    }

    func testSnapshotPublishesAndPreservesMeasuredMemoryBreakdown() {
        let measuredUsage = MemoryUsage(
            percent: 60,
            usedBytes: 6_000,
            totalBytes: 10_000,
            appBytes: 3_000,
            wiredBytes: 2_000,
            compressedBytes: 1_000
        )
        var readings: [MemoryUsage?] = [measuredUsage, nil]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.memory"),
            memoryReader: { readings.removeFirst() }
        )

        let measured = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        let cached = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(measured.memoryAppBytes, 3_000, accuracy: 0.001)
        XCTAssertEqual(measured.memoryWiredBytes, 2_000, accuracy: 0.001)
        XCTAssertEqual(measured.memoryCompressedBytes, 1_000, accuracy: 0.001)
        XCTAssertEqual(cached.memoryUsedBytes, measured.memoryUsedBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryAppBytes, measured.memoryAppBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryWiredBytes, measured.memoryWiredBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryCompressedBytes, measured.memoryCompressedBytes, accuracy: 0.001)
    }

    func testCPUPercentUsesOnlySampleDeltasWithoutOverflowing() throws {
        let sinceBootTicks: [UInt32] = [
            2_500_000_000,
            900_000_000,
            3_000_000_000,
            700_000_000
        ]

        XCTAssertNil(cpuPercent(currentTicks: sinceBootTicks, previousTicks: nil))

        let secondSamplePercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: [2_500_000_060, 900_000_020, 3_000_000_120, 700_000_000],
                previousTicks: sinceBootTicks
            )
        )
        XCTAssertEqual(secondSamplePercent, 40, accuracy: 0.001)

        let largeDeltaPercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: sinceBootTicks,
                previousTicks: [0, 0, 0, 0]
            )
        )
        XCTAssertEqual(
            largeDeltaPercent,
            4_100_000_000.0 / 7_100_000_000.0 * 100,
            accuracy: 0.001
        )

        let wrappedCounterPercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: [5, 120, 230, 310],
                previousTicks: [UInt32.max - 10, 100, 200, 300]
            )
        )
        XCTAssertEqual(wrappedCounterPercent, 46.0 / 76.0 * 100, accuracy: 0.001)

        let allCountersWrapped = try XCTUnwrap(
            cpuUsage(
                currentTicks: [4, 5, 6, 7],
                previousTicks: [UInt32.max - 5, UInt32.max - 4, UInt32.max - 3, UInt32.max - 2]
            )
        )
        XCTAssertEqual(allCountersWrapped.activePercent, 75, accuracy: 0.001)
    }

    func testCommandOutputDrainsLargeOutputBeforeWaitingForExit() {
        let startedAt = Date()
        let output = runStatsCommandOutput(
            "/bin/sh",
            arguments: ["-c", "yes 1234567890 | head -n 20000"],
            timeout: 3
        )

        XCTAssertNotNil(output)
        XCTAssertGreaterThan(output?.count ?? 0, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testCommandOutputTimesOutStuckCommands() {
        let startedAt = Date()
        let output = runStatsCommandOutput("/bin/sleep", arguments: ["5"], timeout: 0.1)

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testSnapshotDoesNotWaitForCommandBackedStatsReaders() {
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in
                Thread.sleep(forTimeInterval: 0.5)
                return nil
            },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.background")
        )

        let startedAt = Date()
        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000), demand: [.processes])

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    }

    func testSnapshotPublishesProcessSamplesAfterBackgroundRefresh() {
        let queue = DispatchQueue(label: "TaskbarStatsSamplerTests.processes")
        let sampler = TaskbarStatsSampler(
            commandOutput: { executable, _ in
                guard executable == "/bin/ps" else { return nil }
                return "987654 45.6 789 /Applications/Foo.app/Contents/MacOS/Foo\n"
            },
            backgroundQueue: queue
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000), demand: [.processes])
        queue.sync {}
        let snapshot = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(snapshot.processes.first?.pid, 987_654)
        XCTAssertEqual(snapshot.processes.first?.cpuPercent, 45.6)
        XCTAssertEqual(snapshot.processes.first?.memoryBytes, 789 * 1024)
    }

    func testUniquePositiveProcessLookupIgnoresInvalidAndDuplicatePIDs() {
        let lookup = uniquePositiveProcessLookup([
            (42, "first"),
            (-1, "transient"),
            (42, "duplicate"),
            (7, "other")
        ])

        XCTAssertEqual(lookup[42], "first")
        XCTAssertEqual(lookup[7], "other")
        XCTAssertNil(lookup[-1])
    }
}
