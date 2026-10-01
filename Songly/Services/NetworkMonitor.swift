//
//  NetworkMonitor.swift
//  Songly
//
//  NWPathMonitor wrapper — publishes network connectivity state.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "cn.wflixu.Songly.network-monitor")

    private(set) var isConnected = true
    private(set) var isExpensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }
}
