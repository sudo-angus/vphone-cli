#!/usr/bin/env python3
"""
Transparent proxy for vphone VM traffic.

Uses macOS pf(4) DIOCNATLOOK to recover the original destination from
redirected connections, then relays data in userspace.

Usage:
    sudo ./scripts/vm_tproxy_start.sh         # start pf rules + proxy
    sudo ./scripts/vm_tproxy_start.sh stop    # tear down
"""

import argparse
import ctypes
import ctypes.util
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from itertools import count

DEFAULT_LISTEN_ADDR = "192.168.64.1"
DEFAULT_LISTEN_PORT = 3129
DEFAULT_CONNECT_TIMEOUT = 30.0
DEFAULT_BACKLOG = 256
BUFSZ = 65536
CONNECTION_IDS = count(1)
STOP_EVENT = threading.Event()

# --- guest DNS forwarder ---
#
# `--tcp-workaround` only redirects guest *TCP* (the pf rdr rule below is
# `proto tcp`), so bare-IP egress works but name resolution does not. In the
# VPN/飞连 environment this helper exists for, the guest's DHCP lease points DNS
# at the bridge (192.168.64.1) yet nothing answers :53 there, so every lookup
# hangs and apps read as "no network". We fill that gap with a userspace
# forwarder on the bridge IP:53 that relays to whatever resolver the *host* is
# currently using — which, being a host process, reaches the corp resolver
# through the same VPN the TCP relay already rides. Reading the upstream fresh
# (short TTL) means a host Wi-Fi/VPN switch is picked up automatically instead
# of leaving the guest on a stale server.
DEFAULT_DNS_PORT = 53
RESOLVER_TTL = 5.0          # re-read the host resolver at most this often
DNS_UPSTREAM_TIMEOUT = 4.0  # per-upstream query timeout
_resolver_cache = {"ts": 0.0, "servers": []}
_resolver_lock = threading.Lock()

# --- macOS pf DIOCNATLOOK via ctypes ---

PF_OUT = 2
AF_INET = socket.AF_INET
IPPROTO_TCP = socket.IPPROTO_TCP
DIOCNATLOOK = 0xC4024417  # _IOWR('D', 23, struct pfioc_natlook)
TCP_KEEPALIVE = getattr(socket, "TCP_KEEPALIVE", 0x10)


class PfAddr(ctypes.Structure):
    """union pf_addr – only the v4 member."""

    _fields_ = [("v4", ctypes.c_uint32), ("pad", ctypes.c_byte * 12)]


class PfiocNatlook(ctypes.Structure):
    """struct pfioc_natlook (macOS)."""

    _fields_ = [
        ("saddr", PfAddr),
        ("daddr", PfAddr),
        ("rsaddr", PfAddr),
        ("rdaddr", PfAddr),
        ("sport", ctypes.c_uint16),
        ("dport", ctypes.c_uint16),
        ("rsport", ctypes.c_uint16),
        ("rdport", ctypes.c_uint16),
        ("af", ctypes.c_uint8),
        ("proto", ctypes.c_uint8),
        ("direction", ctypes.c_uint8),
        ("pad", ctypes.c_byte * 1),
    ]


_pf_fd = None
_libc = None


def log(message):
    print(f"[tproxy] {message}", flush=True)


def log_error(message):
    print(f"[tproxy] {message}", file=sys.stderr, flush=True)


def _pf_dev():
    global _pf_fd
    if _pf_fd is None:
        _pf_fd = os.open("/dev/pf", os.O_RDWR)
    return _pf_fd


def _libc_handle():
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    return _libc


def configure_socket(sock):
    sock.settimeout(None)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPALIVE, 30)
    except OSError:
        pass


def get_original_dest(client_sock):
    """Query pf for the original destination of a redirected connection."""
    sa = client_sock.getpeername()  # (src_ip, src_port)
    la = client_sock.getsockname()  # (rdr_ip, rdr_port) = our listen addr

    nl = PfiocNatlook()
    ctypes.memset(ctypes.addressof(nl), 0, ctypes.sizeof(nl))
    nl.af = AF_INET
    nl.proto = IPPROTO_TCP
    nl.direction = PF_OUT

    nl.saddr.v4 = struct.unpack("!I", socket.inet_aton(sa[0]))[0]
    nl.sport = socket.htons(sa[1])
    nl.daddr.v4 = struct.unpack("!I", socket.inet_aton(la[0]))[0]
    nl.dport = socket.htons(la[1])

    ret = _libc_handle().ioctl(
        ctypes.c_int(_pf_dev()),
        ctypes.c_ulong(DIOCNATLOOK),
        ctypes.byref(nl),
    )
    if ret != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"DIOCNATLOOK failed: {os.strerror(err)}")

    orig_ip = socket.inet_ntoa(struct.pack("!I", nl.rdaddr.v4))
    orig_port = socket.ntohs(nl.rdport)
    return orig_ip, orig_port


def relay(connection_id, src, dst):
    sockets = [src, dst]
    while not STOP_EVENT.is_set():
        readable, _, _ = select.select(sockets, [], [])
        for current in readable:
            peer = dst if current is src else src
            data = current.recv(BUFSZ)
            if not data:
                side = "guest" if current is src else "remote"
                log(f"#{connection_id} {side} closed")
                return
            peer.sendall(data)


def close_quietly(sock):
    if sock is None:
        return
    try:
        sock.close()
    except OSError:
        pass


def _usable_upstream(ip, self_addr):
    """Reject IPv6, the vmnet subnet, and our own bridge as DNS upstreams.

    Forwarding to anything on 192.168.64.0/24 risks pointing back at this very
    listener (a query loop); loopback is fine, since a host-local resolver
    (e.g. a VPN client's own forwarder) answers correctly from the host.
    """
    if not ip or ":" in ip:
        return False
    if ip.startswith("192.168.64."):
        return False
    if ip == self_addr:
        return False
    return True


def _dedup(seq):
    seen = set()
    out = []
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def _resolvers_from_scutil(self_addr):
    try:
        out = subprocess.run(
            ["scutil", "--dns"],
            capture_output=True,
            text=True,
            timeout=3,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    servers = []
    for line in out.splitlines():
        line = line.strip()
        # lines look like: "nameserver[0] : 10.93.128.1"
        if line.startswith("nameserver[") and ":" in line:
            ip = line.split(":", 1)[1].strip()
            if _usable_upstream(ip, self_addr):
                servers.append(ip)
    return _dedup(servers)


def _resolvers_from_resolv_conf(self_addr):
    servers = []
    try:
        with open("/etc/resolv.conf") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver":
                    if _usable_upstream(parts[1], self_addr):
                        servers.append(parts[1])
    except OSError:
        pass
    return _dedup(servers)


def get_upstream_resolvers(self_addr):
    """Host's current DNS servers, cached with a short TTL so a host network
    switch is reflected within RESOLVER_TTL without spawning scutil per query."""
    now = time.monotonic()
    with _resolver_lock:
        if _resolver_cache["servers"] and now - _resolver_cache["ts"] < RESOLVER_TTL:
            return _resolver_cache["servers"]
    servers = _resolvers_from_scutil(self_addr) or _resolvers_from_resolv_conf(self_addr)
    with _resolver_lock:
        _resolver_cache["ts"] = now
        _resolver_cache["servers"] = servers
    return servers


def _forward_dns_udp(server_sock, self_addr, query, client):
    upstreams = get_upstream_resolvers(self_addr)
    if not upstreams:
        log_error("dns/udp: no host upstream resolver available; dropping query")
        return
    for upstream in upstreams:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as up:
                up.settimeout(DNS_UPSTREAM_TIMEOUT)
                up.sendto(query, (upstream, 53))
                resp, _ = up.recvfrom(BUFSZ)
            server_sock.sendto(resp, client)
            return
        except OSError:
            continue
    log_error(f"dns/udp: all upstreams failed for query from {client[0]}")


def dns_udp_forwarder(listen_addr, dns_port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((listen_addr, dns_port))
    except OSError as exc:
        log_error(
            f"dns/udp: bind {listen_addr}:{dns_port} failed ({exc}); DNS forwarding "
            "disabled (another resolver may already serve the bridge)"
        )
        return
    sock.settimeout(1.0)
    log(f"dns/udp forwarder on {listen_addr}:{dns_port} -> host resolver")
    try:
        while not STOP_EVENT.is_set():
            try:
                query, client = sock.recvfrom(BUFSZ)
            except socket.timeout:
                continue
            except OSError:
                if STOP_EVENT.is_set():
                    break
                continue
            threading.Thread(
                target=_forward_dns_udp,
                args=(sock, listen_addr, query, client),
                daemon=True,
            ).start()
    finally:
        close_quietly(sock)


def _forward_dns_tcp(self_addr, client):
    remote = None
    try:
        for upstream in get_upstream_resolvers(self_addr):
            try:
                remote = socket.create_connection((upstream, 53), timeout=DNS_UPSTREAM_TIMEOUT)
                break
            except OSError:
                remote = None
        if remote is None:
            return
        configure_socket(client)
        relay(next(CONNECTION_IDS), client, remote)
    finally:
        close_quietly(client)
        close_quietly(remote)


def dns_tcp_forwarder(listen_addr, dns_port):
    """Large answers (TC bit) retry over TCP; without this those lookups fail."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((listen_addr, dns_port))
    except OSError as exc:
        log_error(f"dns/tcp: bind {listen_addr}:{dns_port} failed ({exc}); TCP DNS disabled")
        return
    srv.listen(64)
    srv.settimeout(1.0)
    log(f"dns/tcp forwarder on {listen_addr}:{dns_port}")
    try:
        while not STOP_EVENT.is_set():
            try:
                client, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                if STOP_EVENT.is_set():
                    break
                continue
            threading.Thread(
                target=_forward_dns_tcp,
                args=(listen_addr, client),
                daemon=True,
            ).start()
    finally:
        close_quietly(srv)


def start_dns_forwarders(listen_addr, dns_port):
    for target in (dns_udp_forwarder, dns_tcp_forwarder):
        threading.Thread(target=target, args=(listen_addr, dns_port), daemon=True).start()


def handle(client, connect_timeout):
    connection_id = next(CONNECTION_IDS)
    remote = None
    try:
        configure_socket(client)
        orig_ip, orig_port = get_original_dest(client)
        remote = socket.create_connection((orig_ip, orig_port), timeout=connect_timeout)
        configure_socket(remote)
        log(f"#{connection_id} {client.getpeername()} -> {orig_ip}:{orig_port}")
        relay(connection_id, client, remote)
    except Exception as exc:
        log_error(f"#{connection_id} error: {exc}")
    finally:
        close_quietly(client)
        close_quietly(remote)


def handle_signal(signum, _frame):
    STOP_EVENT.set()
    signal_name = signal.Signals(signum).name
    log(f"received {signal_name}, shutting down")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-addr", default=DEFAULT_LISTEN_ADDR)
    parser.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    parser.add_argument("--connect-timeout", type=float, default=DEFAULT_CONNECT_TIMEOUT)
    parser.add_argument("--backlog", type=int, default=DEFAULT_BACKLOG)
    parser.add_argument(
        "--dns",
        dest="dns",
        action="store_true",
        default=True,
        help="serve guest DNS on <listen-addr>:<dns-port>, forwarding to the host resolver (default)",
    )
    parser.add_argument("--no-dns", dest="dns", action="store_false")
    parser.add_argument("--dns-port", type=int, default=DEFAULT_DNS_PORT)
    return parser.parse_args()


def main():
    args = parse_args()
    _pf_dev()
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.listen_addr, args.listen_port))
    srv.listen(args.backlog)
    srv.settimeout(1.0)
    log(f"transparent proxy on {args.listen_addr}:{args.listen_port}")

    if args.dns:
        start_dns_forwarders(args.listen_addr, args.dns_port)

    try:
        while not STOP_EVENT.is_set():
            try:
                client, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError as exc:
                if STOP_EVENT.is_set():
                    break
                raise exc
            thread = threading.Thread(
                target=handle,
                args=(client, args.connect_timeout),
                daemon=True,
            )
            thread.start()
    finally:
        close_quietly(srv)
        log("stopped")


if __name__ == "__main__":
    main()
