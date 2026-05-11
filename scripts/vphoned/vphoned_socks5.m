#import "vphoned_socks5.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#define VMADDR_CID_ANY 0xFFFFFFFF

struct sockaddr_vm {
  __uint8_t svm_len;
  sa_family_t svm_family;
  __uint16_t svm_reserved1;
  __uint32_t svm_port;
  __uint32_t svm_cid;
};

// MARK: - I/O helpers

static BOOL read_fully(int fd, void *buf, size_t count) {
  uint8_t *p = (uint8_t *)buf;
  size_t off = 0;
  while (off < count) {
    ssize_t n = read(fd, p + off, count - off);
    if (n <= 0)
      return NO;
    off += (size_t)n;
  }
  return YES;
}

static BOOL write_fully(int fd, const void *buf, size_t count) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t off = 0;
  while (off < count) {
    ssize_t n = write(fd, p + off, count - off);
    if (n <= 0)
      return NO;
    off += (size_t)n;
  }
  return YES;
}

// MARK: - SOCKS5 reply helpers

// Reply codes (RFC 1928 §6).
#define REP_SUCCESS 0x00
#define REP_GENERAL_FAILURE 0x01
#define REP_NOT_ALLOWED 0x02
#define REP_NET_UNREACHABLE 0x03
#define REP_HOST_UNREACHABLE 0x04
#define REP_CONN_REFUSED 0x05
#define REP_TTL_EXPIRED 0x06
#define REP_CMD_UNSUPPORTED 0x07
#define REP_ADDR_UNSUPPORTED 0x08

/// Build & send a SOCKS5 reply with a zero IPv4 BND.ADDR/BND.PORT placeholder.
/// Used for failure paths and as a minimal success when we don't have a
/// resolved bound address handy.
static void send_reply(int fd, uint8_t rep) {
  uint8_t r[10];
  r[0] = 0x05;
  r[1] = rep;
  r[2] = 0x00;
  r[3] = 0x01;        // ATYP IPv4
  memset(&r[4], 0, 4); // BND.ADDR 0.0.0.0
  r[8] = 0;
  r[9] = 0;            // BND.PORT 0
  write_fully(fd, r, sizeof(r));
}

/// Map common errno values from connect() to SOCKS5 reply codes.
static uint8_t errno_to_rep(int e) {
  switch (e) {
  case ECONNREFUSED:
    return REP_CONN_REFUSED;
  case ENETUNREACH:
    return REP_NET_UNREACHABLE;
  case EHOSTUNREACH:
  case EHOSTDOWN:
    return REP_HOST_UNREACHABLE;
  case ETIMEDOUT:
    return REP_TTL_EXPIRED;
  default:
    return REP_GENERAL_FAILURE;
  }
}

// MARK: - Pipe loop

static void splice_loop(int a, int b) {
  // Two-thread byte pump: one direction per thread. Simpler than poll() and
  // the per-connection thread cost is negligible here.
  __block int ab_done = 0;
  __block int ba_done = 0;

  dispatch_queue_t q =
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  void (^pump)(int, int, int *) = ^(int from, int to, int *flag) {
    uint8_t buf[16384];
    while (1) {
      ssize_t n = read(from, buf, sizeof(buf));
      if (n <= 0)
        break;
      if (!write_fully(to, buf, (size_t)n))
        break;
    }
    // Half-close the write side of the peer so the other direction can drain
    // cleanly when one side finishes.
    shutdown(to, SHUT_WR);
    *flag = 1;
    dispatch_semaphore_signal(done);
  };

  dispatch_async(q, ^{
    pump(a, b, &ab_done);
  });
  dispatch_async(q, ^{
    pump(b, a, &ba_done);
  });

  // Wait for both directions.
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

// MARK: - SOCKS5 session

static int connect_target(struct addrinfo *res, uint8_t *out_rep) {
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s < 0)
      continue;
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (connect(s, ai->ai_addr, ai->ai_addrlen) == 0) {
      *out_rep = REP_SUCCESS;
      return s;
    }
    *out_rep = errno_to_rep(errno);
    close(s);
  }
  return -1;
}

static void *handle_session(void *arg) {
  int client = (int)(intptr_t)arg;

  // --- Greeting ---
  // VER (1), NMETHODS (1), METHODS (NMETHODS).
  uint8_t hdr[2];
  if (!read_fully(client, hdr, 2) || hdr[0] != 0x05) {
    close(client);
    return NULL;
  }
  uint8_t nmethods = hdr[1];
  if (nmethods > 0) {
    uint8_t methods[256];
    if (!read_fully(client, methods, nmethods)) {
      close(client);
      return NULL;
    }
  }
  // Reply: NO AUTHENTICATION REQUIRED.
  uint8_t greeting_resp[2] = {0x05, 0x00};
  if (!write_fully(client, greeting_resp, 2)) {
    close(client);
    return NULL;
  }

  // --- Request ---
  // VER (1), CMD (1), RSV (1), ATYP (1), DST.ADDR (var), DST.PORT (2).
  uint8_t req[4];
  if (!read_fully(client, req, 4) || req[0] != 0x05) {
    send_reply(client, REP_GENERAL_FAILURE);
    close(client);
    return NULL;
  }
  uint8_t cmd = req[1];
  uint8_t atyp = req[3];
  if (cmd != 0x01) { // CONNECT only
    send_reply(client, REP_CMD_UNSUPPORTED);
    close(client);
    return NULL;
  }

  char host[256];
  uint8_t addr4[4];
  uint8_t addr6[16];
  uint16_t port_be;

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *res = NULL;
  int gai = 0;

  switch (atyp) {
  case 0x01: { // IPv4
    if (!read_fully(client, addr4, 4) ||
        !read_fully(client, &port_be, 2)) {
      send_reply(client, REP_GENERAL_FAILURE);
      close(client);
      return NULL;
    }
    inet_ntop(AF_INET, addr4, host, sizeof(host));
    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%u", ntohs(port_be));
    hints.ai_family = AF_INET;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    gai = getaddrinfo(host, port_str, &hints, &res);
    break;
  }
  case 0x03: { // DOMAIN
    uint8_t len;
    if (!read_fully(client, &len, 1) || len == 0 ||
        !read_fully(client, host, len) ||
        !read_fully(client, &port_be, 2)) {
      send_reply(client, REP_GENERAL_FAILURE);
      close(client);
      return NULL;
    }
    host[len] = '\0';
    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%u", ntohs(port_be));
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_NUMERICSERV | AI_ADDRCONFIG;
    gai = getaddrinfo(host, port_str, &hints, &res);
    break;
  }
  case 0x04: { // IPv6
    if (!read_fully(client, addr6, 16) ||
        !read_fully(client, &port_be, 2)) {
      send_reply(client, REP_GENERAL_FAILURE);
      close(client);
      return NULL;
    }
    inet_ntop(AF_INET6, addr6, host, sizeof(host));
    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%u", ntohs(port_be));
    hints.ai_family = AF_INET6;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    gai = getaddrinfo(host, port_str, &hints, &res);
    break;
  }
  default:
    send_reply(client, REP_ADDR_UNSUPPORTED);
    close(client);
    return NULL;
  }

  if (gai != 0 || res == NULL) {
    NSLog(@"socks5: getaddrinfo(%s) failed: %s", host,
          gai ? gai_strerror(gai) : "no results");
    send_reply(client, REP_HOST_UNREACHABLE);
    close(client);
    if (res)
      freeaddrinfo(res);
    return NULL;
  }

  uint8_t rep = REP_GENERAL_FAILURE;
  int target = connect_target(res, &rep);
  freeaddrinfo(res);

  if (target < 0) {
    NSLog(@"socks5: connect %s:%u failed: %s", host, ntohs(port_be),
          strerror(errno));
    send_reply(client, rep);
    close(client);
    return NULL;
  }

  send_reply(client, REP_SUCCESS);
  NSLog(@"socks5: %s:%u connected", host, ntohs(port_be));

  splice_loop(client, target);

  close(client);
  close(target);
  return NULL;
}

// MARK: - Listener

static void *listener_thread(void *arg) {
  int sock = (int)(intptr_t)arg;
  for (;;) {
    int client = accept(sock, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR)
        continue;
      NSLog(@"socks5: accept failed: %s", strerror(errno));
      sleep(1);
      continue;
    }
    pthread_t tid;
    if (pthread_create(&tid, NULL, handle_session,
                       (void *)(intptr_t)client) != 0) {
      NSLog(@"socks5: pthread_create failed: %s", strerror(errno));
      close(client);
      continue;
    }
    pthread_detach(tid);
  }
  return NULL;
}

BOOL vp_socks5_start(void) {
  int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (sock < 0) {
    NSLog(@"socks5: socket(AF_VSOCK) failed: %s", strerror(errno));
    return NO;
  }

  int one = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_vm addr = {
      .svm_len = sizeof(struct sockaddr_vm),
      .svm_family = AF_VSOCK,
      .svm_port = VPHONED_SOCKS5_PORT,
      .svm_cid = VMADDR_CID_ANY,
  };

  if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    NSLog(@"socks5: bind failed: %s", strerror(errno));
    close(sock);
    return NO;
  }
  if (listen(sock, 32) < 0) {
    NSLog(@"socks5: listen failed: %s", strerror(errno));
    close(sock);
    return NO;
  }

  pthread_t tid;
  if (pthread_create(&tid, NULL, listener_thread,
                     (void *)(intptr_t)sock) != 0) {
    NSLog(@"socks5: pthread_create(listener) failed: %s", strerror(errno));
    close(sock);
    return NO;
  }
  pthread_detach(tid);

  NSLog(@"socks5: listening on vsock port %d", VPHONED_SOCKS5_PORT);
  return YES;
}

// MARK: - UDP relay (SOCKS5 CMD=0x03 UDP ASSOCIATE)
//
// Each accepted vsock connection on VPHONED_SOCKS5_UDP_PORT is one UDP
// association. The host frames datagrams as:
//
//   [u32 length BE] [u8 atyp] [addr...] [u16 port BE] [payload bytes]
//
//   atyp 0x01 IPv4   : addr is 4 bytes
//   atyp 0x03 DOMAIN : addr is [u8 namelen][name bytes]
//   atyp 0x04 IPv6   : addr is 16 bytes
//
//   `length` = total bytes after itself (atyp + addr + port + payload).
//
// host→guest: target addr/port + payload to send (guest does sendto).
// guest→host: source addr/port (numeric) + payload received.
//
// One dual-stack UDP socket per association lets us send to both v4 and v6
// targets and receive replies on a single fd. kqueue muxes vsock + udp.

#define UDP_FRAME_ATYP_IPV4   0x01
#define UDP_FRAME_ATYP_DOMAIN 0x03
#define UDP_FRAME_ATYP_IPV6   0x04
#define UDP_FRAME_MAX_LEN     (16 * 1024)

// Decode [atyp][addr][port] from a host→guest frame body. On DOMAIN, fill
// `out_domain` and set `*out_is_domain = 1`; caller must getaddrinfo() it.
// Returns header length consumed (>0) on success, 0 on malformed input.
static int udp_decode_addr(const uint8_t *body, size_t body_len,
                           struct sockaddr_storage *out_addr,
                           socklen_t *out_addr_len,
                           int *out_is_domain,
                           char *out_domain, size_t out_domain_cap,
                           uint16_t *out_port_host) {
  if (body_len < 1)
    return 0;
  uint8_t atyp = body[0];
  size_t off = 1;
  *out_is_domain = 0;
  memset(out_addr, 0, sizeof(*out_addr));

  switch (atyp) {
  case UDP_FRAME_ATYP_IPV4: {
    if (body_len < 1 + 4 + 2)
      return 0;
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)out_addr;
    sin6->sin6_len = sizeof(*sin6);
    sin6->sin6_family = AF_INET6;
    // IPv4-mapped IPv6: ::FFFF:a.b.c.d so the dual-stack socket can sendto v4.
    sin6->sin6_addr.s6_addr[10] = 0xff;
    sin6->sin6_addr.s6_addr[11] = 0xff;
    memcpy(&sin6->sin6_addr.s6_addr[12], body + off, 4);
    off += 4;
    uint16_t port_be;
    memcpy(&port_be, body + off, 2);
    off += 2;
    sin6->sin6_port = port_be;
    *out_port_host = ntohs(port_be);
    *out_addr_len = sizeof(*sin6);
    return (int)off;
  }
  case UDP_FRAME_ATYP_IPV6: {
    if (body_len < 1 + 16 + 2)
      return 0;
    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)out_addr;
    sin6->sin6_len = sizeof(*sin6);
    sin6->sin6_family = AF_INET6;
    memcpy(&sin6->sin6_addr, body + off, 16);
    off += 16;
    uint16_t port_be;
    memcpy(&port_be, body + off, 2);
    off += 2;
    sin6->sin6_port = port_be;
    *out_port_host = ntohs(port_be);
    *out_addr_len = sizeof(*sin6);
    return (int)off;
  }
  case UDP_FRAME_ATYP_DOMAIN: {
    if (body_len < 2)
      return 0;
    uint8_t nl = body[off++];
    if (nl == 0 || body_len < (size_t)(1 + 1 + nl + 2))
      return 0;
    if ((size_t)nl >= out_domain_cap)
      return 0;
    memcpy(out_domain, body + off, nl);
    out_domain[nl] = '\0';
    off += nl;
    uint16_t port_be;
    memcpy(&port_be, body + off, 2);
    off += 2;
    *out_port_host = ntohs(port_be);
    *out_is_domain = 1;
    return (int)off;
  }
  default:
    return 0;
  }
}

// Resolve a domain to one usable sockaddr for SOCK_DGRAM sendto on a
// dual-stack v6 socket. AI_V4MAPPED ensures v4 results come back as
// IPv4-mapped sockaddr_in6, so we don't have to switch sockets.
static int udp_resolve_domain(const char *host, uint16_t port,
                              struct sockaddr_storage *out,
                              socklen_t *out_len) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_family = AF_INET6;
  hints.ai_flags = AI_NUMERICSERV | AI_V4MAPPED | AI_ADDRCONFIG;

  char port_str[8];
  snprintf(port_str, sizeof(port_str), "%u", port);

  struct addrinfo *res = NULL;
  int gai = getaddrinfo(host, port_str, &hints, &res);
  if (gai != 0 || res == NULL) {
    if (res)
      freeaddrinfo(res);
    return -1;
  }
  for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
    if (ai->ai_addrlen <= sizeof(*out)) {
      memcpy(out, ai->ai_addr, ai->ai_addrlen);
      *out_len = ai->ai_addrlen;
      freeaddrinfo(res);
      return 0;
    }
  }
  freeaddrinfo(res);
  return -1;
}

// Encode source addr from recvfrom() as a frame header. v4-mapped v6 is
// flattened back to ATYP=IPv4 so the host doesn't need to special-case it.
// Returns bytes written into `out` (which must be >= 19 bytes).
static size_t udp_encode_source(const struct sockaddr_storage *addr,
                                uint8_t *out) {
  if (addr->ss_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    if (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr)) {
      out[0] = UDP_FRAME_ATYP_IPV4;
      memcpy(out + 1, &sin6->sin6_addr.s6_addr[12], 4);
      memcpy(out + 5, &sin6->sin6_port, 2);
      return 7;
    } else {
      out[0] = UDP_FRAME_ATYP_IPV6;
      memcpy(out + 1, &sin6->sin6_addr, 16);
      memcpy(out + 17, &sin6->sin6_port, 2);
      return 19;
    }
  } else if (addr->ss_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    out[0] = UDP_FRAME_ATYP_IPV4;
    memcpy(out + 1, &sin->sin_addr, 4);
    memcpy(out + 5, &sin->sin_port, 2);
    return 7;
  }
  return 0;
}

static void handle_udp_session(int vsock_fd) {
  int udp_fd = socket(AF_INET6, SOCK_DGRAM, 0);
  if (udp_fd < 0) {
    NSLog(@"socks5-udp: socket(v6) failed: %s", strerror(errno));
    close(vsock_fd);
    return;
  }
  int zero = 0;
  setsockopt(udp_fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));

  // Ephemeral port on in6addr_any: guest routing picks the egress iface
  // (incl. any active utun from a VPN PacketTunnelProvider).
  struct sockaddr_in6 bind_addr;
  memset(&bind_addr, 0, sizeof(bind_addr));
  bind_addr.sin6_len = sizeof(bind_addr);
  bind_addr.sin6_family = AF_INET6;
  if (bind(udp_fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
    NSLog(@"socks5-udp: bind failed: %s", strerror(errno));
    close(udp_fd);
    close(vsock_fd);
    return;
  }

  int kq = kqueue();
  if (kq < 0) {
    NSLog(@"socks5-udp: kqueue failed: %s", strerror(errno));
    close(udp_fd);
    close(vsock_fd);
    return;
  }
  struct kevent changes[2];
  EV_SET(&changes[0], vsock_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  EV_SET(&changes[1], udp_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  if (kevent(kq, changes, 2, NULL, 0, NULL) < 0) {
    NSLog(@"socks5-udp: kevent register failed: %s", strerror(errno));
    close(kq);
    close(udp_fd);
    close(vsock_fd);
    return;
  }

  uint8_t inbuf[UDP_FRAME_MAX_LEN];
  uint8_t pkt[UDP_FRAME_MAX_LEN];

  for (;;) {
    struct kevent ev;
    int n = kevent(kq, NULL, 0, &ev, 1, NULL);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (n == 0)
      continue;

    if ((int)ev.ident == vsock_fd) {
      // Host frame arrived: [u32 len][atyp][addr][port][payload] → sendto.
      uint8_t lenbuf[4];
      if (!read_fully(vsock_fd, lenbuf, 4))
        break;
      uint32_t len = ((uint32_t)lenbuf[0] << 24) |
                     ((uint32_t)lenbuf[1] << 16) |
                     ((uint32_t)lenbuf[2] << 8) | (uint32_t)lenbuf[3];
      if (len == 0 || len > UDP_FRAME_MAX_LEN) {
        NSLog(@"socks5-udp: bad frame length %u", len);
        break;
      }
      if (!read_fully(vsock_fd, inbuf, len))
        break;

      struct sockaddr_storage target;
      socklen_t target_len = 0;
      int is_domain = 0;
      char domain[256];
      uint16_t port_host = 0;
      int hdr_len =
          udp_decode_addr(inbuf, len, &target, &target_len, &is_domain,
                          domain, sizeof(domain), &port_host);
      if (hdr_len <= 0) {
        NSLog(@"socks5-udp: malformed frame header (len=%u)", len);
        continue;
      }
      if (is_domain) {
        if (udp_resolve_domain(domain, port_host, &target, &target_len) != 0) {
          NSLog(@"socks5-udp: getaddrinfo(%s) failed", domain);
          continue;
        }
      }
      const uint8_t *payload = inbuf + hdr_len;
      size_t payload_len = (size_t)len - (size_t)hdr_len;
      ssize_t sent = sendto(udp_fd, payload, payload_len, 0,
                            (struct sockaddr *)&target, target_len);
      if (sent < 0) {
        // Per-datagram failures are normal (host/route down); don't tear down.
        NSLog(@"socks5-udp: sendto failed: %s", strerror(errno));
      }

      if (ev.flags & EV_EOF)
        break;
    } else if ((int)ev.ident == udp_fd) {
      struct sockaddr_storage src;
      socklen_t src_len = sizeof(src);
      ssize_t r = recvfrom(udp_fd, pkt, sizeof(pkt), 0,
                           (struct sockaddr *)&src, &src_len);
      if (r < 0) {
        if (errno == EINTR)
          continue;
        NSLog(@"socks5-udp: recvfrom failed: %s", strerror(errno));
        break;
      }

      uint8_t hdr[19];
      size_t hdr_len = udp_encode_source(&src, hdr);
      if (hdr_len == 0)
        continue;

      size_t body_len = hdr_len + (size_t)r;
      uint8_t lenbuf[4];
      lenbuf[0] = (uint8_t)((body_len >> 24) & 0xff);
      lenbuf[1] = (uint8_t)((body_len >> 16) & 0xff);
      lenbuf[2] = (uint8_t)((body_len >> 8) & 0xff);
      lenbuf[3] = (uint8_t)(body_len & 0xff);

      // writev is atomic vs. other writers on a stream socket, so partial
      // writes only happen when the socket is non-blocking or the peer
      // disappears. Treat partial as fatal: the framing must stay aligned.
      struct iovec iov[3];
      iov[0].iov_base = lenbuf;
      iov[0].iov_len = 4;
      iov[1].iov_base = hdr;
      iov[1].iov_len = hdr_len;
      iov[2].iov_base = pkt;
      iov[2].iov_len = (size_t)r;
      ssize_t total_expected = (ssize_t)(4 + body_len);
      ssize_t written = writev(vsock_fd, iov, 3);
      if (written != total_expected) {
        if (written < 0)
          NSLog(@"socks5-udp: writev failed: %s", strerror(errno));
        else
          NSLog(@"socks5-udp: partial writev (%zd/%zd), tearing down",
                written, total_expected);
        break;
      }
    }
  }

  close(kq);
  close(udp_fd);
  close(vsock_fd);
}

static void *udp_session_thread(void *arg) {
  int vsock_fd = (int)(intptr_t)arg;
  handle_udp_session(vsock_fd);
  return NULL;
}

static void *udp_listener_thread(void *arg) {
  int sock = (int)(intptr_t)arg;
  for (;;) {
    int client = accept(sock, NULL, NULL);
    if (client < 0) {
      if (errno == EINTR)
        continue;
      NSLog(@"socks5-udp: accept failed: %s", strerror(errno));
      sleep(1);
      continue;
    }
    pthread_t tid;
    if (pthread_create(&tid, NULL, udp_session_thread,
                       (void *)(intptr_t)client) != 0) {
      NSLog(@"socks5-udp: pthread_create failed: %s", strerror(errno));
      close(client);
      continue;
    }
    pthread_detach(tid);
  }
  return NULL;
}

BOOL vp_socks5_udp_start(void) {
  int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (sock < 0) {
    NSLog(@"socks5-udp: socket(AF_VSOCK) failed: %s", strerror(errno));
    return NO;
  }
  int one = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  struct sockaddr_vm addr = {
      .svm_len = sizeof(struct sockaddr_vm),
      .svm_family = AF_VSOCK,
      .svm_port = VPHONED_SOCKS5_UDP_PORT,
      .svm_cid = VMADDR_CID_ANY,
  };
  if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    NSLog(@"socks5-udp: bind failed: %s", strerror(errno));
    close(sock);
    return NO;
  }
  if (listen(sock, 32) < 0) {
    NSLog(@"socks5-udp: listen failed: %s", strerror(errno));
    close(sock);
    return NO;
  }
  pthread_t tid;
  if (pthread_create(&tid, NULL, udp_listener_thread,
                     (void *)(intptr_t)sock) != 0) {
    NSLog(@"socks5-udp: pthread_create(listener) failed: %s",
          strerror(errno));
    close(sock);
    return NO;
  }
  pthread_detach(tid);

  NSLog(@"socks5-udp: listening on vsock port %d", VPHONED_SOCKS5_UDP_PORT);
  return YES;
}
