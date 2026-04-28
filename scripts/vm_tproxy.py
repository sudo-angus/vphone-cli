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
import sys
import threading
from itertools import count

DEFAULT_LISTEN_ADDR = "192.168.64.1"
DEFAULT_LISTEN_PORT = 3129
DEFAULT_CONNECT_TIMEOUT = 30.0
DEFAULT_BACKLOG = 256
BUFSZ = 65536
CONNECTION_IDS = count(1)
STOP_EVENT = threading.Event()

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
