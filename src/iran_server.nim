import std/[strformat, strutils, random, endians]
import chronos , chronos/transports/datagram , chronos/osdefs
import times, print, connection, pipe
from globals import nil

type
    TunnelConnectionPoolContext = object
        # listener_server: Connection # for testing on local pc
        listener: StreamServer
        user_inbounds: Connections
        user_inbounds_udp: UdpConnections
        available_peer_inbounds: Connections
        peer_ip: IpAddress


var context = TunnelConnectionPoolContext()

proc monitorData(data: var string): bool =
    try:
        let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
        if data.high.uint8 < base + 4: return false
        var sh1_c: uint32
        var sh2_c: uint32

        copyMem(addr sh1_c, addr data[base+0], 4)
        copyMem(addr sh2_c, addr data[base+4], 4)

        let chk1 = sh1_c == globals.sh1
        let chk2 = sh2_c == globals.sh2

        if (chk1 and chk2):

            return true
        else:
            return false

    except:
        return false

proc generateFinishHandShakeData(): string =
    let rlen: uint16 = uint16(16*(6+rand(4)))
    var random_trust_data: string = newStringOfCap(rlen)
    random_trust_data.setLen(rlen)

    copyMem(addr random_trust_data[0], addr(globals.random_str[rand(250)]), rlen)
    copyMem(addr random_trust_data[0], addr globals.tls13_record_layer[0], 3) #tls header
    copyMem(addr random_trust_data[3], addr rlen, 2) #tls len

    let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
    copyMem(addr random_trust_data[base+0], addr globals.sh3.uint32, 4)
    copyMem(addr random_trust_data[base+4], addr globals.sh4.uint32, 4)

    return random_trust_data


proc acquireRemoteConnection(mark = true): Future[Connection] {.async.} =
    var remote: Connection = nil
    for i in 0..<200:
        if context.available_peer_inbounds.len != 0:
            remote = context.available_peer_inbounds[0]
            if remote != nil:
                if remote.closed or remote.exhausted:
                    context.available_peer_inbounds.remove(remote)
                    continue
                
                if mark:
                    inc remote.counter
                    remote.exhausted = remote.counter >= globals.mux_width
                return remote
        await sleepAsync(10)
    return nil

proc connectTargetSNI(): Future[Connection] {.async.} =
    let address = initTAddress(globals.final_target_ip, globals.final_target_port)
    var new_remote: Connection = await connection.connect(address)
    new_remote.trusted = TrustStatus.no
    if globals.log_conn_create: echo "connected to ", globals.final_target_domain, ":", $globals.final_target_port
    return new_remote

proc processTrustedRemote(remote: Connection) {.async.} =
    var data = newStringOfCap(4200)
    var boundary: uint16 = 0
    var cid: uint16
    var port: uint16
    var flag: uint8

    try:
        while not remote.isNil and not remote.closed:
            #read
            data.setlen remote.reader.tsource.offset
            if data.len() == 0:
                if remote.reader.atEof():
                    break
                else:
                    discard await remote.reader.readOnce(addr data, 0)
                    continue

            if boundary == 0:
                let width = int(globals.full_tls_record_len + globals.mux_record_len)
                data.setLen width
                await remote.reader.readExactly(addr data[0], width)
                copyMem(addr boundary, addr data[3], sizeof(boundary))
                if boundary == 0: break

                copyMem(addr cid, addr data[globals.full_tls_record_len], sizeof(cid))
                copyMem(addr flag, addr data[globals.full_tls_record_len.int + sizeof(cid) + sizeof(port)], sizeof(flag))

                cid = cid xor boundary
                flag = flag xor boundary.uint8

                boundary -= globals.mux_record_len.uint16
                if boundary == 0:
                    context.user_inbounds.with(cid, child_client):
                        child_client.close()
                        context.user_inbounds.remove(child_client)
                continue

            let readable = min(boundary, data.len().uint16)
            boundary -= readable; data.setlen readable
            await remote.reader.readExactly(addr data[0], readable.int)
            if globals.log_data_len: echo &"[processRemote] {data.len()} bytes from remote"


            # write
            if DataFlags.udp in cast[TransferFlags](flag):
                context.user_inbounds_udp.with(cid, child_client):
                    unPackForRead(data)
                    child_client.hit()
                    
                    if not child_client.closed:
                        await child_client.transp.sendTo(child_client.raddr, data)
                        if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> client"
                    inc remote.udp_packets; if remote.udp_packets > globals.udp_max_ppc: remote.close()
                    
            else:
                if context.user_inbounds.hasID(cid):
                    context.user_inbounds.with(cid, child_client):
                        unPackForRead(data)
                        if not child_client.closed:
                            await child_client.writer.write(data)
                            if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> client"
                else:
                    await remote.writer.write(closeSignalData(cid))

            if globals.noise_ratio != 0:
                data.packForSend(remote.id, remote.port.uint16, flags = {DataFlags.junk})
                for _ in 0..<globals.noise_ratio:
                    await remote.writer.write(data)
                    if globals.log_data_len: echo &"{data.len} Junk bytes -> Remote"

    except:
        if globals.log_conn_error: echo getCurrentExceptionMsg()
    #close
    context.available_peer_inbounds.remove(remote)
    await remote.closeWait()

proc processTcpConnection(client: Connection) {.async.} =
    proc closeLine(remote, client: Connection) {.async.} =
        if globals.log_conn_destory: echo "closed client & remote"
        if remote != nil:
            await allFutures(remote.closeWait(), client.closeWait())
        else:
            await client.closeWait()

    proc processUntrustedRemote(remote: Connection) {.async.} =
        var data = newStringOfCap(4200)
        try:
            while not remote.isNil and not remote.closed:
                #read
                data.setlen remote.reader.tsource.offset
                if data.len() == 0:
                    if remote.reader.atEof():
                        await closeLine(client, remote)
                        return
                    else:
                        discard await remote.reader.readOnce(addr data, 0)
                        continue

                await remote.reader.readExactly(addr data[0], data.len)
                if globals.log_data_len: echo &"[processRemote] {data.len()} bytes from remote"

                # write
                if not client.closed:
                    await client.writer.write(data)
                    if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> client "
        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()
        #close
        await remote.closeWait()
        if not client.isTrusted():
            await client.closeWait()


    proc processClient(remote: Connection) {.async.} =
        var remote = remote
        var data = newString(len = 0)
        var first_packet = true
        try:
            while not client.closed:
                #read
                data.setlen client.reader.tsource.offset
                if data.len() == 0:
                    if client.reader.atEof():
                        break
                    else:
                        discard await client.reader.readOnce(addr data, 0)
                        continue
                if client.trusted == TrustStatus.no:
                    let width = globals.full_tls_record_len.int + globals.mux_record_len.int
                    data.setLen(data.len() + width)
                    await client.reader.readExactly(addr data[0 + width], data.len - width)
                else:
                    await client.reader.readExactly(addr data[0], data.len)

                if globals.log_data_len: echo &"[processClient] {data.len()} bytes from client {client.id}"

                #trust based route
                if client.trusted == TrustStatus.pending:

                    var trust = monitorData(data)
                    if trust:
                        #peer connection
                        client.trusted = TrustStatus.yes
                        let address = client.transp.remoteAddress()
                        print "Peer Fake Handshake Complete ! ", address
                        context.available_peer_inbounds.register(client)
                        context.peer_ip = client.transp.remoteAddress.address
                        remote.close() # close untrusted remote
                        asyncCheck processTrustedRemote(client)

                        return
                    else:
                        if first_packet:
                            if not data.contains(globals.final_target_domain):
                                if globals.trusted_foreign_peers.len != 0 or  context.peer_ip != IpAddress():
                                    #user wants to use panel via iran ip
                                    client.trusted = TrustStatus.pending
                                else:
                                    echo "[Error] user connection but no peer connected yet."
                                    await closeLine(client, remote)
                                    return
                        if not (globals.trusted_foreign_peers.len != 0 or  context.peer_ip != IpAddress()):
                            if (epochTime().uint - client.creation_time) > globals.trust_time:
                                #user connection but no peer connected yet
                                #peer connection but couldnt finish handshake in time
                                client.trusted = TrustStatus.no
                                await closeLine(client, remote)
                                return

                    first_packet = false


                #write
                if remote.closed:
                    remote.close()
                    remote = await acquireRemoteConnection()
                    if remote == nil:
                        if globals.log_conn_error: echo &"[Error] left without connection, closes forcefully."
                        await closeLine(client, remote); return

                if remote.isTrusted:
                    data.packForSend(client.id, client.port.uint16)
                await remote.writer.write(data)

                if globals.log_data_len: echo &"{data.len} bytes -> Remote"

                if globals.noise_ratio != 0 and remote.isTrusted:
                    data.flagForSend(flags = {DataFlags.junk})
                    for _ in 0..<globals.noise_ratio:
                        await remote.writer.write(data)
                        if globals.log_data_len: echo &"{data.len} Junk bytes -> Remote"

        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

        #close
        client.close()
        context.user_inbounds.remove(client)

        try:
            if remote.closed:
                remote = await acquireRemoteConnection(mark = false)

                if remote != nil:
                    await remote.writer.write(closeSignalData(client.id))     
            else:
                await remote.writer.write(closeSignalData(client.id))
                remote.counter.dec
                if remote.exhausted and remote.counter == 0:
                    context.available_peer_inbounds.remove(remote)
                    remote.close()
                    if globals.log_conn_destory: echo "Closed a exhausted mux connection"

            
        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()


    #Initialize remote
    try:
        var remote: Connection = nil
        if globals.trusted_foreign_peers.len != 0 and
            client.transp.remoteAddress.address in globals.trusted_foreign_peers:
            #load balancer connection
            remote = await connectTargetSNI()
            asyncCheck processUntrustedRemote(remote)

        elif context.peer_ip != IpAddress() and
            context.peer_ip != client.transp.remoteAddress.address:
            if globals.log_conn_create: echo "Real User connected !"
            client.trusted = TrustStatus.no
            remote = await acquireRemoteConnection() #associate peer
            if remote != nil:
                if globals.log_conn_create: echo "Associated a peer connection, cid: ", remote.id
                context.user_inbounds.register(client)

            else:
                echo &"[AssociatedCon][Error] left without connection, closes forcefully."
                await client.closeWait()
                return
        else:
            remote = await connectTargetSNI()
            asyncCheck processUntrustedRemote(remote)

        asyncCheck processClient(remote)

    except:
        printEx()


proc processUdpPacket(client:UdpConnection) {.async.} =
    

    proc processClient(remote: Connection) {.async.} =
        try:
            var remote = remote
            var pbytes = client.transp.getMessage()
            var nbytes = len(pbytes)
            let width = globals.full_tls_record_len.int + globals.mux_record_len.int

            if nbytes > 0:
                var data = newStringOfCap(cap = nbytes + width); data.setlen(nbytes + width)
                copyMem(addr data[0 + width], addr pbytes[0], data.len - width)
                if globals.log_data_len: echo &"[processClient] {data.len()} bytes from client {client.id}"

                #write
                if remote.closed:
                    remote = await acquireRemoteConnection()
                    if remote == nil:
                        if globals.log_conn_error: echo &"[Error] left without connection, closes forcefully."
                        return

                data.packForSend(client.id, client.port.uint16)
                await remote.writer.write(data)

                if globals.log_data_len: echo &"{data.len} bytes -> Remote"
                if globals.noise_ratio != 0:
                    data.flagForSend(flags = {DataFlags.junk})
                    for _ in 0..<globals.noise_ratio:
                        await remote.writer.write(data)
                        if globals.log_data_len: echo &"{data.len} Junk bytes -> Remote"

                client.hit()
                inc remote.udp_packets; if remote.udp_packets > globals.udp_max_ppc: remote.close()
            else:
                client.close()
                context.user_inbounds_udp.remove(client)
        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

   
    #Initialize remote
    try:
        if globals.log_conn_create: echo "Real User connected (UDP) !"
        var remote = await acquireRemoteConnection(mark = false) #associate peer
        
        if remote != nil:
            if globals.log_conn_create: echo "Associated a peer connection, cid: ", remote.id
        else:
            echo &"[AssociatedCon][Error] left without connection, closes forcefully."
            await client.closeWait()
            return
        await processClient(remote)

    except:
        printEx()



proc start*(){.async.} =
    var pbuf = newString(len = 16)

    proc startTcpListener(){.async.} =

        proc serveStreamClient(server: StreamServer,
                        transp: StreamTransport) {.async.} =
            try:
                let con = await Connection.new(transp)
                let address = con.transp.remoteAddress()
                if globals.multi_port:
                    var origin_port: int
                    var size = 16
                    if not getSockOpt(transp.fd, int(globals.SOL_IP), int(globals.SO_ORIGINAL_DST),
                    addr pbuf[0], size):
                        echo "multiport failure getting origin port. !"
                        await con.closeWait()
                        return
                    bigEndian16(addr origin_port, addr pbuf[2])

                    con.port = origin_port.Port

                    if globals.log_conn_create: print "Connected client: ", address, con.port
                else:
                    con.port = server.local.port.Port
                    if globals.log_conn_create: print "Connected client: ", address

                asyncCheck processTcpConnection(con)
            except:
                echo "handle client connection error:"
                echo getCurrentExceptionMsg()


        var address = initTAddress(globals.listen_addr6, globals.listen_port.Port)

        let server: StreamServer =
            try:
                createStreamServer(address, serveStreamClient, {ReuseAddr})
            except TransportOsError as exc:
                raise exc
            except CatchableError as exc:
                raise exc
        context.listener = server

        if globals.multi_port:
            assert globals.listen_port == server.localAddress().port
            # globals.listen_port = server.localAddress().port # its must be same as listen port

            globals.createIptablesForwardRules()

        server.start()
        echo &"Started tcp server  {globals.listen_addr6}:{globals.listen_port}"


    proc startUdpListener() {.async.} =

        proc handleDatagram(transp: DatagramTransport,
                    raddr: TransportAddress): Future[void] {.async.} =

                var (found,connection) = findUdp(context.user_inbounds_udp,raddr)
                if not found: 
                    connection = UdpConnection.new(transp,raddr)
                    context.user_inbounds_udp.register connection

                let address = raddr
                if globals.log_conn_create: print "Connected client: ", address

                if globals.multi_port:
                    var origin_port: int
                    var size = 16
                    if not getSockOpt(connection.transp.fd, int(globals.SOL_IP), int(globals.SO_ORIGINAL_DST),
                    addr pbuf[0], size):
                        echo "multiport failure getting origin port. !"
                        await connection.closeWait()
                        return
                    bigEndian16(addr origin_port, addr pbuf[2])

                    connection.port = origin_port.Port

                    if globals.log_conn_create: print "Connected client: ", address, connection.port
                else:
                    # connection.port = transp.localAddress.port.Port
                    connection.port = globals.listen_port
                    if globals.log_conn_create: print "Connected client: ", address


                asyncCheck processUdpPacket(connection)

        var address4 = initTAddress(globals.listen_addr4, globals.listen_port.Port)
        var address6 = initTAddress(globals.listen_addr6, globals.listen_port.Port)

        var dgramServer4 = newDatagramTransport(handleDatagram, local = address4,flags = {ReuseAddr})
        echo &"Started udp server  {globals.listen_addr4}:{globals.listen_port}"
        var dgramServer6 = newDatagramTransport6(handleDatagram, local = address6,flags = {ReuseAddr})
        echo &"Started udp server  {globals.listen_addr6}:{globals.listen_port}"

        await dgramServer4.join() and dgramServer6.join()
        echo "Udp server ended."

    # trackIdleConnections(context.available_peer_inbounds, globals.pool_age)

    await sleepAsync(200)
    if globals.accept_udp:
        echo &"Mode Iran (Tcp + Udp): {globals.self_ip}  handshake: {globals.final_target_domain}"
    else:
        echo &"Mode Iran: {globals.self_ip}  handshake: {globals.final_target_domain}"

    
    asyncCheck startTcpListener()
    if globals.accept_udp:
        trackDeadUdpConnections(context.user_inbounds_udp,globals.udp_max_idle_time)
        asyncCheck startUdpListener()


    # asyncCheck start_server_listener()





