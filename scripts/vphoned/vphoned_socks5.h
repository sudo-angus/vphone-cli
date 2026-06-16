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

#define VPHONED_SOCKS5_PORT     1340  // TCP CONNECT sessions (vsock)
#define VPHONED_SOCKS5_UDP_PORT 1341  // UDP relay frame channel (vsock)
#define VPHONED_SOCKS5_TCP_PORT 1080  // direct TCP SOCKS5 over the vmnet IP

/// Spawn a detached thread that runs the TCP CONNECT vsock listener.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_start(void);

/// Spawn a detached thread that runs the UDP relay vsock listener.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_udp_start(void);

/// Spawn a detached thread that runs a *plain TCP/IP* SOCKS5 listener on
/// `0.0.0.0:port`. This is the direct path: the host (Surge) connects straight
/// to the guest's vmnet IP, so no vsock and no `VZVirtioSocketDevice.connect()`
/// is involved — the Apple Virtualization helper (and its connect-churn wedge)
/// is entirely out of the data path, and the kernel handles concurrency
/// natively. Sessions reuse the same handler as the vsock path, so domain
/// resolution and egress (incl. active iOS VPN utun routes) behave identically.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_tcp_start(uint16_t port);

/// Pin a stable IPv4 alias (host octet 250) on the vmnet `en*` interface, so
/// the host can target a fixed `…/24 .250` address regardless of what the
/// per-boot DHCP lease assigns. Returns the alias address string on success
/// (the value to point Surge at), or nil if no vmnet interface was found or the
/// alias could not be added.
NSString *vp_socks5_setup_alias(void);
