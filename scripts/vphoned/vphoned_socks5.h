/*
 * vphoned_socks5 — SOCKS5 server over vsock.
 *
 * Listens on a dedicated vsock port. Each accepted vsock connection is a
 * single SOCKS5 session: greeting (no auth) → CONNECT (IPv4/IPv6/DOMAIN) →
 * full-duplex byte splice between the vsock client and the target socket.
 *
 * Domain names resolve via getaddrinfo() inside the guest, so any DNS
 * pushed by an active iOS VPN is used. Connections are issued from the
 * guest, so the iOS routing table — including utun interfaces installed
 * by VPN PacketTunnelProvider extensions — applies transparently to
 * every CONNECT.
 */

#pragma once
#import <Foundation/Foundation.h>

#define VPHONED_SOCKS5_PORT 1340

/// Spawn a detached thread that runs the SOCKS5 vsock listener.
/// Returns YES if the listener was bound; NO on socket/bind/listen failure.
BOOL vp_socks5_start(void);
