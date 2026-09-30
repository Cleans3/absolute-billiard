#!/usr/bin/env python3
"""Tunnel relay: the fallback when Noray's direct punch fails (docs/plan/06 P10, 04 §2.3).

Noray's own relay addresses a player by the ip:port its registrar saw, so it cannot reach a host whose
NAT hands out a new port per destination (symmetric NAT: many mobile carriers). Here both ends talk to
ONE UDP port per joiner and the relay learns each address from a token packet sent to that very port,
so it works behind any NAT.

Control (TCP, `name text\\n`, same framing as Noray):
  host  -> `host CODE`     <- `host ok` | `host taken`        (connection stays open = the registration)
  join  -> `join CODE`     <- `tunnel PORT TOKEN` | `tunnel 0 unknown|full`
                           host also gets `tunnel PORT TOKEN` (its own token)
Data (UDP on PORT): `AB<token>` teaches the relay that sender's address (the joiner gets `OK` back);
everything else is forwarded verbatim between the two learned addresses.

  tunnel.py [control_port=8893] [first_udp_port=49252] [udp_port_count=100]
  tunnel.py --selftest
"""
import asyncio
import re
import secrets
import sys
import time

IDLE_SEC = 120  # a tunnel with no packet for this long is freed (ENet's own timeout is 45-60 s)
GRACE_SEC = 5  # after its host leaves, a tunnel still carries the goodbye packets for this long
MAX_PER_HOST = 8  # tunnels one host may hold: max_players - 1, plus rejoin slack
CODE = re.compile(r"^[0-9A-Z]{4,12}$")
MAGIC = b"AB"


class Tunnel(asyncio.DatagramProtocol):
    def __init__(self, code, port, host_token, join_token):
        self.code, self.port = code, port
        self.tokens = (MAGIC + host_token.encode(), MAGIC + join_token.encode())
        self.ends = [None, None]  # [host address, joiner address]
        self.last = time.monotonic()
        self.close_at = float("inf")
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.last = time.monotonic()
        if data in self.tokens:
            side = self.tokens.index(data)
            self.ends[side] = addr
            if side == 1:
                self.transport.sendto(b"OK", addr)
        elif addr in self.ends and None not in self.ends:
            self.transport.sendto(data, self.ends[1 - self.ends.index(addr)])


class Relay:
    def __init__(self, first_port, count, bind="0.0.0.0", grace=GRACE_SEC):
        self.free = list(range(first_port, first_port + count))
        self.bind, self.grace = bind, grace
        self.hosts = {}  # code -> the host's control connection
        self.tunnels = []

    async def open_tunnel(self, code):
        host = self.hosts.get(code)
        if host is None:
            return "tunnel 0 unknown"
        if not self.free or sum(t.code == code for t in self.tunnels) >= MAX_PER_HOST:
            return "tunnel 0 full"
        port, host_token, join_token = self.free.pop(0), secrets.token_hex(8), secrets.token_hex(8)
        tunnel = Tunnel(code, port, host_token, join_token)
        try:
            await asyncio.get_running_loop().create_datagram_endpoint(lambda: tunnel, local_addr=(self.bind, port))
        except OSError:
            return "tunnel 0 full"  # port taken by something else: leave it out of the pool
        self.tunnels.append(tunnel)
        host.write(f"tunnel {port} {host_token}\n".encode())
        return f"tunnel {port} {join_token}"

    async def client(self, reader, writer):
        hosted = None
        try:
            while True:
                line = (await reader.readline())[:64].decode("ascii", "ignore").strip()
                if not line:
                    break
                name, _, code = line.partition(" ")
                if not CODE.match(code):
                    continue
                if name == "host" and hosted is None:
                    if code in self.hosts:
                        writer.write(b"host taken\n")
                    else:
                        hosted = code
                        self.hosts[code] = writer
                        writer.write(b"host ok\n")
                elif name == "join":
                    writer.write((await self.open_tunnel(code) + "\n").encode())
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            if hosted is not None:
                del self.hosts[hosted]
                for tunnel in self.tunnels:
                    if tunnel.code == hosted:
                        tunnel.close_at = time.monotonic() + self.grace
            writer.close()

    async def reap(self, every=1.0, idle=IDLE_SEC):
        while True:
            await asyncio.sleep(every)
            now = time.monotonic()
            for tunnel in [t for t in self.tunnels if now - t.last > idle or now > t.close_at]:
                tunnel.transport.close()
                self.tunnels.remove(tunnel)
                self.free.append(tunnel.port)


async def serve(control_port, first_port, count):
    relay = Relay(first_port, count)
    server = await asyncio.start_server(relay.client, "0.0.0.0", control_port)
    print(f"tunnel relay: control tcp {control_port}, udp {first_port}-{first_port + count - 1}", flush=True)
    async with server:
        await asyncio.gather(server.serve_forever(), relay.reap())


async def selftest():
    relay = Relay(47300, 2, "127.0.0.1", grace=0.2)
    server = await asyncio.start_server(relay.client, "127.0.0.1", 0)
    control = server.sockets[0].getsockname()[1]
    loop = asyncio.get_running_loop()

    async def line(reader):
        return (await asyncio.wait_for(reader.readline(), 2)).decode().strip()

    async def udp():
        queue = asyncio.Queue()
        proto = type("P", (asyncio.DatagramProtocol,), {"datagram_received": lambda s, d, a: queue.put_nowait(d)})
        transport, _ = await loop.create_datagram_endpoint(proto, local_addr=("127.0.0.1", 0))
        return transport, queue

    async def silent(queue):
        try:
            await asyncio.wait_for(queue.get(), 0.2)
            return False
        except asyncio.TimeoutError:
            return True

    jr, jw = await asyncio.open_connection("127.0.0.1", control)
    jw.write(b"join AB3K7Q\n")
    assert await line(jr) == "tunnel 0 unknown", "join before any host"

    hr, hw = await asyncio.open_connection("127.0.0.1", control)
    hw.write(b"host AB3K7Q\n")
    assert await line(hr) == "host ok"
    r2, w2 = await asyncio.open_connection("127.0.0.1", control)
    w2.write(b"host AB3K7Q\n")
    assert await line(r2) == "host taken", "a second host cannot squat a live code"

    jw.write(b"join AB3K7Q\n")
    _, port, join_token = (await line(jr)).split()
    _, host_port, host_token = (await line(hr)).split()
    assert port == host_port and join_token != host_token
    to = ("127.0.0.1", int(port))
    host, host_q = await udp()
    joiner, join_q = await udp()
    stranger, stranger_q = await udp()

    joiner.sendto(b"early", to)  # nothing learned yet: dropped, not an error
    joiner.sendto(MAGIC + join_token.encode(), to)
    assert await asyncio.wait_for(join_q.get(), 2) == b"OK", "joiner token is acknowledged"
    joiner.sendto(b"before-host", to)
    assert await silent(host_q), "no forwarding until the host is known"
    host.sendto(MAGIC + b"0" * 16, to)  # wrong token must not teach an address
    host.sendto(MAGIC + host_token.encode(), to)
    await asyncio.sleep(0.05)
    joiner.sendto(b"ping", to)
    assert await asyncio.wait_for(host_q.get(), 2) == b"ping", "joiner -> host"
    host.sendto(b"pong", to)
    assert await asyncio.wait_for(join_q.get(), 2) == b"pong", "host -> joiner"
    stranger.sendto(b"spoof", to)
    assert await silent(host_q) and await silent(join_q) and await silent(stranger_q), "a third address is ignored"

    jw.write(b"join AB3K7Q\njoin AB3K7Q\n")
    assert (await line(jr)).split()[1] != "0" and await line(hr)
    assert await line(jr) == "tunnel 0 full", "the pool is bounded"

    reaper = asyncio.create_task(relay.reap(every=0.05, idle=0.3))
    await asyncio.sleep(0.6)
    assert len(relay.free) == 2 and not relay.tunnels, "idle tunnels return to the pool"

    jw.write(b"join AB3K7Q\n")
    _, port, join_token = (await line(jr)).split()
    _, _, host_token = (await line(hr)).split()
    to = ("127.0.0.1", int(port))
    host.sendto(MAGIC + host_token.encode(), to)
    joiner.sendto(MAGIC + join_token.encode(), to)
    assert await asyncio.wait_for(join_q.get(), 2) == b"OK"
    hw.close()
    await asyncio.sleep(0.05)
    assert "AB3K7Q" not in relay.hosts, "host leaving frees its code at once"
    host.sendto(b"bye", to)
    assert await asyncio.wait_for(join_q.get(), 2) == b"bye", "the goodbye still crosses during the grace time"
    jw.write(b"join AB3K7Q\n")
    assert await line(jr) == "tunnel 0 unknown"
    await asyncio.sleep(0.5)
    reaper.cancel()
    assert len(relay.free) == 2, "and its tunnels follow after the grace time"
    print("TUNNEL OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        asyncio.run(selftest())
    else:
        args = [int(a) for a in sys.argv[1:]]
        asyncio.run(serve(*(args + [8893, 49252, 100][len(args):])))
