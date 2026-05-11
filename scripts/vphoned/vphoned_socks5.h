/*
 * vphoned_socks5 — SOCKS5 over vsock (TCP CONNECT + UDP relay).
 *
 * Two vsock ports:
 *   - VPHONED_SOCKS5_PORT (TCP CONNECT): each accepted vsock connection is
 *     a single SOCKS5 session — greeting → CONNECT → full-duplex byte
 *     splice between the vsock client and the target socket.
 *   - VPHONED_SOCKS5_UDP_PORT (UDP relay): each accepted vsock connection
 *     is one SOCKS5 UDP association — a length-prefixed frame channel that
 *     carries datagrams in both directions. See vphoned_socks5.m for the
 *     frame format. The host terminates the SOCKS5 UDP ASSOCIATE handshake
 *     and uses this channel to ship datagrams in/out of the guest.
 *
 * Domain names resolve via getaddrinfo() inside the guest, so DNS pushed
 * by an active iOS VPN is used. Sends are issued from the guest, so the
 * iOS routing table — including utun interfaces installed by VPN
 * PacketTunnelProvider extensions — applies transparently.
 */

#pragma once
#import <Foundation/Foundation.h>

#define VPHONED_SOCKS5_PORT     1340  // TCP CONNECT sessions
#define VPHONED_SOCKS5_UDP_PORT 1341  // UDP relay frame channel

/// Spawn a detached thread that runs the TCP CONNECT vsock listener.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_start(void);

/// Spawn a detached thread that runs the UDP relay vsock listener.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_udp_start(void);
