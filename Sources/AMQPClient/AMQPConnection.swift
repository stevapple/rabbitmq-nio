import NIO
import NIOSSL
import AMQPProtocol

final class AMQPConnection {
    let channel: NIO.Channel
    let eventLoopGroup: EventLoopGroup

    init(channel: NIO.Channel, eventLoopGroup: EventLoopGroup) {
        self.channel = channel
        self.eventLoopGroup = eventLoopGroup
    }

    static func create(use eventLoopGroup: EventLoopGroup, from config: Configuration) -> EventLoopFuture<AMQPConnection> {
        return self.boostrapChannel(use: eventLoopGroup, from: config)
            .map { AMQPConnection(channel: $0, eventLoopGroup: eventLoopGroup) }
    }

    static func boostrapChannel(use eventLoopGroup: EventLoopGroup, from config: Configuration) -> EventLoopFuture<NIO.Channel> {
        let eventLoop = eventLoopGroup.next()
        let channelPromise = eventLoop.makePromise(of: NIO.Channel.self)
        let serverConfig: Configuration.Server
    
        switch config {
        case .tls(_, _, let server):
            serverConfig = server
        case .plain(let server):
            serverConfig = server
        }

        do {
            let bootstrap = try boostrapClient(use: eventLoopGroup, from: config)

            bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .connectTimeout(serverConfig.timeout)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(AMQPFrameHandler(config: serverConfig))
                }
                .connect(host: serverConfig.host, port: serverConfig.port)
                .map { channelPromise.succeed($0) }
                .cascadeFailure(to: channelPromise)
        } catch {
            channelPromise.fail(error)
        }

        return channelPromise.futureResult        
    }

    static func boostrapClient(use eventLoopGroup: EventLoopGroup, from config: Configuration) throws -> NIOClientTCPBootstrap {
        guard let clientBootstrap = ClientBootstrap(validatingGroup: eventLoopGroup) else {
            preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
        }

        switch config {            
        case .plain(_): 
            return NIOClientTCPBootstrap(clientBootstrap, tls: NIOInsecureNoTLS())
        case .tls(let tls, let sniServerName, let server):
            let sslContext = try NIOSSLContext(configuration: tls ?? TLSConfiguration.makeClientConfiguration())
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: sniServerName ?? server.host)
            let bootstrap = NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
            return bootstrap.enableTLS()
        }        
    }

    func sendBytes(eventLoop: EventLoop? = nil, bytes: [UInt8], immediate: Bool = false) -> EventLoopFuture<AMQPResponse> {
        return sendFrame(eventLoop: eventLoop, outbound: .bytes(bytes), immediate: immediate)
    }


    func sendFrame(eventLoop: EventLoop? = nil, frame: AMQPProtocol.Frame, immediate: Bool = false) -> EventLoopFuture<AMQPResponse> {
        return sendFrame(eventLoop: eventLoop, outbound: .frame(frame), immediate: immediate)
    }

    private func sendFrame(eventLoop: EventLoop? = nil, outbound: AMQPFrameHandler.AMQPOutbound, immediate: Bool = false) -> EventLoopFuture<AMQPResponse> {
        let eventLoop = eventLoop ?? self.eventLoopGroup.any()
        let promise = eventLoop.makePromise(of: AMQPResponse.self)
        let outboundData = (outbound, promise)

        let writeFuture = immediate ? self.channel.writeAndFlush(outboundData) : self.channel.write(outboundData)

        return writeFuture
            .flatMap{ promise.futureResult }
    }

    func close() -> EventLoopFuture<Void> {
        if self.channel.isActive {
            return self.channel.close()
        } else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
    }

    func closeFuture() -> EventLoopFuture<Void> {
        return self.channel.closeFuture
    }
}
