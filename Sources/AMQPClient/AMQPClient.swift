//===----------------------------------------------------------------------===//
//
// This source file is part of the RabbitMQNIO project
//
// Copyright (c) 2022 Krzysztof Majk
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIO
import Dispatch
import NIOConcurrencyHelpers
import AMQPProtocol

public final class AMQPClient {
    private let eventLoopGroup: EventLoopGroup
    private let eventLoopGroupProvider: NIOEventLoopGroupProvider
    private let config: AMQPClientConfiguration

    private let isShutdown = ManagedAtomic(false)

    private var lock = NIOLock()
    private var _connection: AMQPConnection?
    private var connection: AMQPConnection? {
        get {
            self.lock.withLock {
                _connection
            }
        }
        set {
            self.lock.withLock {
                _connection = newValue
            }
        }
    }

    /// EventLoop used by a connection.
    public var eventLoop: EventLoop? { return self.connection?.eventLoop }

    /// Future that resolves when connection is closed.
    public var closeFuture: EventLoopFuture<Void>? {
        get { return self._connection?.closeFuture }
    }

    public init(eventLoopGroupProvider: NIOEventLoopGroupProvider, config: AMQPClientConfiguration) {
        self.config = config
        self.eventLoopGroupProvider = eventLoopGroupProvider

        switch eventLoopGroupProvider {
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        case .shared(let elg):
            self.eventLoopGroup = elg
        }
    }

    /// Connect to broker.
    /// - Returns: EventLoopFuture with result confirming that broker has accepted a request.
    @discardableResult
    public func connect() ->  EventLoopFuture<AMQPResponse.Connection.Connected> {
        return AMQPConnection.create(use: self.eventLoopGroup, from: self.config)
            .flatMap { connection  in 
                self.connection = connection
                connection.closeFuture.whenComplete { result in
                    if self.connection === connection {
                        self.connection = nil
                    }
                }

                let response: EventLoopFuture<AMQPResponse> = connection.write(channelID: 0, outbound: .bytes(PROTOCOL_START_0_9_1), immediate: true)
                return response
            }
            .flatMapThrowing { response in
                guard case .connection(let connection) = response, case .connected(let connected) = connection else {
                    throw AMQPClientError.invalidResponse(response)
                }
                return connected
            }
    }

    /// Open new channel.
    /// Can be used only when connection is connected.
    /// - Parameters:
    ///     - id: Channel Identifer must be unique and greater then 0.
    /// - Returns: EventLoopFuture with AMQP Channel.
    public func openChannel(id: Frame.ChannelID) -> EventLoopFuture<AMQPChannel> {
        guard let connection = self.connection else { return self.eventLoopGroup.any().makeFailedFuture(AMQPClientError.connectionClosed()) }

        return connection.openChannel(frame: .method(id, .channel(.open(reserved1: ""))), immediate: true)
            .flatMapThrowing  { response in 
                guard case .channel(let channel) = response, case .opened(let opened) = channel, opened.channelID == id else {
                    throw AMQPClientError.invalidResponse(response)
                }

                return AMQPChannel(channelID: id, eventLoopGroup: self.eventLoopGroup, notifier: opened.notifier, connection: connection)
            }
    }

    /// Close a connection.
    /// - Parameters:
    ///     - reason: Reason that can be logged by broker.
    ///     - code: Code that can be logged by broker.
    /// - Returns: EventLoopFuture waiting for close response.
    public func close(reason: String = "", code: UInt16 = 200) -> EventLoopFuture<Void> {
        guard let connection = self.connection else { return self.eventLoopGroup.any().makeFailedFuture(AMQPClientError.connectionClosed()) }

        return connection.write(channelID: 0, outbound: .frame(.method(0, .connection(.close(.init(replyCode: code, replyText: reason, failingClassID: 0, failingMethodID: 0))))), immediate: true)
        .flatMapThrowing { response in
            guard case .connection(let connection) = response, case .closed = connection else {
                throw AMQPClientError.invalidResponse(response)
            }
            return ()
        }
    }

    /// Shutdown a connection with eventloop.
    /// - Parameters:
    ///     - queue: DispatchQueue for eventloop shutdown.
    ///     - callback: Function that will be executed after stop.
    public func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void) {
        guard self.isShutdown.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            callback(AMQPClientError.alreadyShutdown)
            return
        }

        let eventLoop = self.eventLoopGroup.next()
        let closeFuture: EventLoopFuture<Void>

        if let connection = self.connection {
            closeFuture = connection.close()
        } else {
            closeFuture = eventLoop.makeSucceededVoidFuture()
        }

        closeFuture.whenComplete { result in
            let closeError: Error?
            switch result {
            case .failure(let error):
                if case ChannelError.alreadyClosed = error {
                    closeError = nil
                } else {
                    closeError = error
                }
            case .success:
                closeError = nil
            }

            self.shutdownEventLoopGroup(queue: queue) { error in
                callback(closeError ?? error)
            }
        }
    }

    private func shutdownEventLoopGroup(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        switch self.eventLoopGroupProvider {
        case .shared:
            queue.async {
                callback(nil)
            }
        case .createNew:
            self.eventLoopGroup.shutdownGracefully(queue: queue, callback)
        }
    }

    deinit {
        guard isShutdown.load(ordering: .relaxed) else {
            preconditionFailure("Client not shut down before the deinit. Please call client.syncShutdownGracefully() when no longer needed.")
        }
    }
}
