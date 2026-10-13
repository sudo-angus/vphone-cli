// Guest sockets own DNS resolution and egress, including iOS VPN routes.
// Data uses TCP/IP, never VSOCK. RPC only configures this optional service.
#include "Include/VphonedSocks5.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>

struct session {
    int client;
    int target;
    bool cancelled;
    struct session *next;
};
static pthread_mutex_t sessions_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t configuration_lock = PTHREAD_MUTEX_INITIALIZER;
static struct session *sessions;
static int session_count;
static int listener_fd = -1;
static int wake_pipe[2] = {-1, -1};
static pthread_t listener_tid;
static uint16_t active_port;
// Reserve descriptor headroom for the HTTP API, files and app installation.
#define MAX_SESSIONS 256

static bool read_fully(int fd, void *buf, size_t count) {
  uint8_t *p = (uint8_t *)buf;
  size_t off = 0;
  while (off < count) {
    ssize_t n = read(fd, p + off, count - off);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    off += (size_t)n;
  }
  return true;
}

static bool write_fully(int fd, const void *buf, size_t count) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t off = 0;
  while (off < count) {
    ssize_t n = write(fd, p + off, count - off);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    off += (size_t)n;
  }
  return true;
}

#define REP_SUCCESS 0x00
#define REP_GENERAL_FAILURE 0x01
#define REP_NOT_ALLOWED 0x02
#define REP_NET_UNREACHABLE 0x03
#define REP_HOST_UNREACHABLE 0x04
#define REP_CONN_REFUSED 0x05
#define REP_TTL_EXPIRED 0x06
#define REP_CMD_UNSUPPORTED 0x07
#define REP_ADDR_UNSUPPORTED 0x08

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

static void splice_loop(int a, int b) {
  int fds[2] = {a, b};
  for (int i = 0; i < 2; i++) {
    int fl = fcntl(fds[i], F_GETFL, 0);
    if (fl >= 0)
      fcntl(fds[i], F_SETFL, fl | O_NONBLOCK);
    int one = 1;
    setsockopt(fds[i], SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
  }

  struct relay_dir {
    int from;
    int to;
    uint8_t buf[65536];
    size_t len; // bytes buffered
    size_t off; // bytes already written from buf
    int read_eof;
    int done;
  } d[2] = {
      {.from = a, .to = b},
      {.from = b, .to = a},
  };

  const int idle_ms = 10 * 60 * 1000;

  while (!(d[0].done && d[1].done)) {
    struct pollfd pf[2] = {{.fd = a, .events = 0}, {.fd = b, .events = 0}};
    for (int i = 0; i < 2; i++) {
      if (!d[i].read_eof && d[i].len == 0)
        (d[i].from == a ? &pf[0] : &pf[1])->events |= POLLIN;
      if (d[i].len > d[i].off)
        (d[i].to == a ? &pf[0] : &pf[1])->events |= POLLOUT;
    }
    if (pf[0].events == 0 && pf[1].events == 0)
      break;

    int n = poll(pf, 2, idle_ms);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (n == 0)
      break; // idle timeout — reap

#define REVENTS(fd) ((fd) == a ? pf[0].revents : pf[1].revents)
    for (int i = 0; i < 2; i++) {
      if (d[i].len > d[i].off &&
          (REVENTS(d[i].to) & (POLLOUT | POLLERR | POLLHUP))) {
        ssize_t w = write(d[i].to, d[i].buf + d[i].off, d[i].len - d[i].off);
        if (w > 0) {
          d[i].off += (size_t)w;
          if (d[i].off == d[i].len)
            d[i].len = d[i].off = 0;
        } else if (w < 0 && errno != EAGAIN && errno != EINTR) {
          d[i].read_eof = 1;
          d[i].len = d[i].off = 0;
        }
      }
      if (!d[i].read_eof && d[i].len == 0 &&
          (REVENTS(d[i].from) & (POLLIN | POLLERR | POLLHUP))) {
        ssize_t r = read(d[i].from, d[i].buf, sizeof(d[i].buf));
        if (r > 0) {
          d[i].len = (size_t)r;
          d[i].off = 0;
          ssize_t w = write(d[i].to, d[i].buf, d[i].len);
          if (w > 0) {
            d[i].off = (size_t)w;
            if (d[i].off == d[i].len)
              d[i].len = d[i].off = 0;
          } else if (w < 0 && errno != EAGAIN && errno != EINTR) {
            d[i].read_eof = 1;
            d[i].len = d[i].off = 0;
          }
        } else if (r == 0) {
          d[i].read_eof = 1;
        } else if (errno != EAGAIN && errno != EINTR) {
          d[i].read_eof = 1;
          d[i].len = d[i].off = 0;
        }
      }
      if (d[i].read_eof && d[i].len == 0 && !d[i].done) {
        shutdown(d[i].to, SHUT_WR);
        d[i].done = 1;
      }
    }
#undef REVENTS
  }
}

static int connect_target(struct addrinfo *res, uint8_t *out_rep) {
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s < 0)
      continue;
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
int flags = fcntl(s, F_GETFL, 0);
fcntl(s, F_SETFL, flags | O_NONBLOCK);
int connected = connect(s, ai->ai_addr, ai->ai_addrlen);
if (connected < 0 && errno == EINPROGRESS) {
  struct pollfd pending = {.fd = s, .events = POLLOUT};
  int ready;
  do { ready = poll(&pending, 1, 10000); } while (ready < 0 && errno == EINTR);
  int error = ETIMEDOUT;
  socklen_t length = sizeof(error);
  if (ready > 0) getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &length);
  errno = error;
  connected = error == 0 ? 0 : -1;
}
fcntl(s, F_SETFL, flags);
if (connected == 0) {
      *out_rep = REP_SUCCESS;
      return s;
    }
    *out_rep = errno_to_rep(errno);
    close(s);
  }
  return -1;
}

static void handle_udp_associate_direct(int client_fd);

static bool read_and_discard_addr(int fd, uint8_t atyp) {
  uint8_t tmp[256];
  switch (atyp) {
  case 0x01: // IPv4 + port
    return read_fully(fd, tmp, 4) && read_fully(fd, tmp, 2);
  case 0x04: // IPv6 + port
    return read_fully(fd, tmp, 16) && read_fully(fd, tmp, 2);
  case 0x03: { // DOMAIN + port
    uint8_t len;
    if (!read_fully(fd, &len, 1))
      return false;
    if (len > 0 && !read_fully(fd, tmp, len))
      return false;
    return read_fully(fd, tmp, 2);
  }
  default:
    return false;
  }
}

static void run_session(struct session *session) {
  int client = session->client;

  uint8_t hdr[2];
  if (!read_fully(client, hdr, 2) || hdr[0] != 0x05) {
    return;
  }
  uint8_t nmethods = hdr[1];
  bool accepts_no_auth = false;
  if (nmethods > 0) {
    uint8_t methods[256];
    if (!read_fully(client, methods, nmethods)) {
      return;
    }
    for (int i = 0; i < nmethods; i++) accepts_no_auth |= methods[i] == 0;
  }
  uint8_t greeting_resp[2] = {0x05, accepts_no_auth ? 0x00 : 0xff};
  if (!write_fully(client, greeting_resp, 2)) {
    return;
  }

  if (!accepts_no_auth) return;

  uint8_t req[4];
  if (!read_fully(client, req, 4) || req[0] != 0x05 || req[2] != 0) {
    send_reply(client, REP_GENERAL_FAILURE);
    return;
  }
  uint8_t cmd = req[1];
  uint8_t atyp = req[3];

  if (cmd == 0x03) { // UDP ASSOCIATE — served on the direct/plain-IP path only
    if (!read_and_discard_addr(client, atyp)) {
      send_reply(client, REP_GENERAL_FAILURE);
      return;
    }
    handle_udp_associate_direct(client);
    return;
  }
  if (cmd != 0x01) { // otherwise CONNECT only
    send_reply(client, REP_CMD_UNSUPPORTED);
    return;
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
      return;
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
      return;
    }
    if (memchr(host, 0, len)) { send_reply(client, REP_ADDR_UNSUPPORTED); return; }
    host[len] = 0;
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
      return;
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
    return;
  }

  if (gai != 0 || res == NULL) {
    fprintf(stderr, "socks5: getaddrinfo(%s) failed: %s\n", host,
          gai ? gai_strerror(gai) : "no results");
    send_reply(client, REP_HOST_UNREACHABLE);
    if (res)
      freeaddrinfo(res);
    return;
  }

  uint8_t rep = REP_GENERAL_FAILURE;
  int target = connect_target(res, &rep);
  pthread_mutex_lock(&sessions_lock);
  if (session->cancelled && target >= 0) { close(target); target = -1; }
  session->target = target;
  pthread_mutex_unlock(&sessions_lock);
  freeaddrinfo(res);

  if (target < 0) {
    fprintf(stderr, "socks5: connect %s:%u failed: %s\n", host, ntohs(port_be),
          strerror(errno));
    send_reply(client, rep);
    return;
  }

  send_reply(client, REP_SUCCESS);
  fprintf(stderr, "socks5: %s:%u connected\n", host, ntohs(port_be));

  splice_loop(client, target);
  pthread_mutex_lock(&sessions_lock);
  session->target = -1;
  close(target);
  pthread_mutex_unlock(&sessions_lock);
  return;
}

#define UDP_FRAME_ATYP_IPV4   0x01
#define UDP_FRAME_ATYP_DOMAIN 0x03
#define UDP_FRAME_ATYP_IPV6   0x04


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
    if (memchr(out_domain, 0, nl)) return 0;
    out_domain[nl] = 0;
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

static int udp_resolve_domain(const char *host, uint16_t port,
                              struct sockaddr_storage *out,
                              socklen_t *out_len) {
  struct addrinfo hints = {.ai_socktype = SOCK_DGRAM, .ai_family = AF_UNSPEC,
                          .ai_flags = AI_NUMERICSERV | AI_ADDRCONFIG};
  char service[8];
  snprintf(service, sizeof(service), "%u", port);
  struct addrinfo *results = NULL;
  if (getaddrinfo(host, service, &hints, &results) != 0) return -1;
  // NAT/tunnel and many corporate VPNs carry IPv4 only. Prefer an A result;
  // retain IPv6 for destinations that have no IPv4 address.
  struct addrinfo *chosen = NULL;
  for (struct addrinfo *entry = results; entry; entry = entry->ai_next) {
    if (entry->ai_family == AF_INET) { chosen = entry; break; }
    if (!chosen && entry->ai_family == AF_INET6) chosen = entry;
  }
  if (!chosen) { freeaddrinfo(results); return -1; }
  memset(out, 0, sizeof(*out));
  if (chosen->ai_family == AF_INET) {
    const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)chosen->ai_addr;
    struct sockaddr_in6 *mapped = (struct sockaddr_in6 *)out;
    mapped->sin6_len = sizeof(*mapped);
    mapped->sin6_family = AF_INET6;
    mapped->sin6_port = ipv4->sin_port;
    mapped->sin6_addr.s6_addr[10] = mapped->sin6_addr.s6_addr[11] = 255;
    memcpy(&mapped->sin6_addr.s6_addr[12], &ipv4->sin_addr, 4);
    *out_len = sizeof(*mapped);
  } else {
    memcpy(out, chosen->ai_addr, chosen->ai_addrlen);
    *out_len = chosen->ai_addrlen;
  }
  freeaddrinfo(results);
  return 0;
}

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

static void handle_udp_associate_direct(int client_fd) {
  struct sockaddr_in local;
  socklen_t local_len = sizeof(local);
  if (getsockname(client_fd, (struct sockaddr *)&local, &local_len) != 0 ||
      local.sin_family != AF_INET) {
    fprintf(stderr, "socks5-udp-direct: control conn is not AF_INET; refusing\n");
    send_reply(client_fd, REP_CMD_UNSUPPORTED);
    return;
  }

  int cli_fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (cli_fd < 0) {
    fprintf(stderr, "socks5-udp-direct: client socket failed: %s\n", strerror(errno));
    send_reply(client_fd, REP_NET_UNREACHABLE); // diag: 0x03
    return;
  }
  struct sockaddr_in bind_addr = local;
  bind_addr.sin_port = 0; // ephemeral
  if (bind(cli_fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
    fprintf(stderr, "socks5-udp-direct: bind to %s failed (%s); retrying INADDR_ANY\n",
          inet_ntoa(local.sin_addr), strerror(errno));
    struct sockaddr_in any;
    memset(&any, 0, sizeof(any));
    any.sin_len = sizeof(any);
    any.sin_family = AF_INET;
    any.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(cli_fd, (struct sockaddr *)&any, sizeof(any)) < 0) {
      fprintf(stderr, "socks5-udp-direct: client bind failed: %s\n", strerror(errno));
      close(cli_fd);
      send_reply(client_fd, REP_HOST_UNREACHABLE); // diag: 0x04
      return;
    }
  }
  struct sockaddr_in bound;
  socklen_t bound_len = sizeof(bound);
  getsockname(cli_fd, (struct sockaddr *)&bound, &bound_len);

  int out_fd = socket(AF_INET6, SOCK_DGRAM, 0);
  if (out_fd < 0) {
    fprintf(stderr, "socks5-udp-direct: out socket failed: %s\n", strerror(errno));
    close(cli_fd);
    send_reply(client_fd, REP_CONN_REFUSED); // diag: 0x05
    return;
  }
  int zero = 0;
  setsockopt(out_fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
  struct sockaddr_in6 out_bind;
  memset(&out_bind, 0, sizeof(out_bind));
  out_bind.sin6_len = sizeof(out_bind);
  out_bind.sin6_family = AF_INET6;
  if (bind(out_fd, (struct sockaddr *)&out_bind, sizeof(out_bind)) < 0) {
    fprintf(stderr, "socks5-udp-direct: out bind failed: %s\n", strerror(errno));
    close(cli_fd);
    close(out_fd);
    send_reply(client_fd, REP_TTL_EXPIRED); // diag: 0x06
    return;
  }

  uint8_t reply[10];
  reply[0] = 0x05;
  reply[1] = REP_SUCCESS;
  reply[2] = 0x00;
  reply[3] = 0x01;
  memcpy(&reply[4], &local.sin_addr, 4);
  memcpy(&reply[8], &bound.sin_port, 2);
  if (!write_fully(client_fd, reply, sizeof(reply))) {
    close(cli_fd);
    close(out_fd);
    return;
  }
  fprintf(stderr, "socks5-udp-direct: association up, BND %s:%u\n",
        inet_ntoa(local.sin_addr), ntohs(bound.sin_port));

  int kq = kqueue();
  if (kq < 0) {
    close(cli_fd);
    close(out_fd);
    return;
  }
  struct kevent changes[3];
  EV_SET(&changes[0], client_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  EV_SET(&changes[1], cli_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  EV_SET(&changes[2], out_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  if (kevent(kq, changes, 3, NULL, 0, NULL) < 0) {
    fprintf(stderr, "socks5-udp-direct: kevent register failed: %s\n", strerror(errno));
    close(kq);
    close(cli_fd);
    close(out_fd);
    return;
  }

  struct sockaddr_in client_src; // latched on first client datagram
  int have_client_src = 0;
  uint8_t pkt[65535];

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

    if ((int)ev.ident == client_fd) {
      break;
    } else if ((int)ev.ident == cli_fd) {
      struct sockaddr_in src;
      socklen_t src_len = sizeof(src);
      ssize_t r = recvfrom(cli_fd, pkt, sizeof(pkt), 0,
                           (struct sockaddr *)&src, &src_len);
      if (r < 0) {
        if (errno == EINTR)
          continue;
        break;
      }
      if (r < 3 || pkt[0] != 0x00 || pkt[1] != 0x00)
        continue;
      if (pkt[2] != 0x00) // FRAG unsupported per RFC
        continue;
struct sockaddr_in peer;
socklen_t peer_length = sizeof(peer);
if (getpeername(client_fd, (struct sockaddr *)&peer, &peer_length) != 0 ||
    src.sin_addr.s_addr != peer.sin_addr.s_addr ||
    (have_client_src && src.sin_port != client_src.sin_port)) continue;
client_src = src;
have_client_src = 1;

      struct sockaddr_storage target;
      socklen_t target_len = 0;
      int is_domain = 0;
      char domain[256];
      uint16_t port_host = 0;
      int hdr_len = udp_decode_addr(pkt + 3, (size_t)r - 3, &target,
                                    &target_len, &is_domain, domain,
                                    sizeof(domain), &port_host);
      if (hdr_len <= 0)
        continue;
      if (is_domain) {
        if (udp_resolve_domain(domain, port_host, &target, &target_len) != 0) {
          fprintf(stderr, "socks5-udp-direct: getaddrinfo(%s) failed\n", domain);
          continue;
        }
      }
      const uint8_t *payload = pkt + 3 + hdr_len;
      size_t payload_len = (size_t)r - 3 - (size_t)hdr_len;
      if (sendto(out_fd, payload, payload_len, 0, (struct sockaddr *)&target,
                 target_len) < 0) {
        fprintf(stderr, "socks5-udp-direct: sendto failed: %s\n", strerror(errno));
      }
    } else if ((int)ev.ident == out_fd) {
      struct sockaddr_storage rsrc;
      socklen_t rsrc_len = sizeof(rsrc);
      ssize_t r = recvfrom(out_fd, pkt, sizeof(pkt), 0,
                           (struct sockaddr *)&rsrc, &rsrc_len);
      if (r < 0) {
        if (errno == EINTR)
          continue;
        break;
      }
      if (!have_client_src)
        continue; // no client to reply to yet

      uint8_t hdr[19];
      size_t hl = udp_encode_source(&rsrc, hdr);
      if (hl == 0)
        continue;
      uint8_t out[3 + 19 + 65535];
      out[0] = 0x00;
      out[1] = 0x00;
      out[2] = 0x00;
      memcpy(out + 3, hdr, hl);
      memcpy(out + 3 + hl, pkt, (size_t)r);
      sendto(cli_fd, out, 3 + hl + (size_t)r, 0,
             (struct sockaddr *)&client_src, sizeof(client_src));
    }

    if (ev.flags & EV_EOF && (int)ev.ident == client_fd)
      break;
  }

  close(kq);
  close(cli_fd);
  close(out_fd);
}


static void *session_thread(void *argument) {
    struct session *session = argument;
    run_session(session);
    pthread_mutex_lock(&sessions_lock);
    struct session **link = &sessions;
    while (*link != session) link = &(*link)->next;
    *link = session->next;
    session_count--;
    // Remove and close under the same lock: stop never shuts down a reused fd.
    close(session->client);
    pthread_mutex_unlock(&sessions_lock);
    free(session);
    return NULL;
}

static void *listener_thread(void *argument) {
    (void)argument;
    struct pollfd descriptors[2] = {
        {.fd = listener_fd, .events = POLLIN},
        {.fd = wake_pipe[0], .events = POLLIN}
    };
    for (;;) {
        int ready = poll(descriptors, 2, -1);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || descriptors[1].revents) break;
        if (!(descriptors[0].revents & POLLIN)) continue;
        int client = accept(descriptors[0].fd, NULL, NULL);
        if (client < 0) continue;
        int one = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        struct timeval timeout = {.tv_sec = 15};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        struct session *session = calloc(1, sizeof(*session));
        pthread_mutex_lock(&sessions_lock);
        if (!session || session_count >= MAX_SESSIONS) {
            pthread_mutex_unlock(&sessions_lock);
            free(session);
            close(client);
            continue;
        }
        session->client = client;
        session->target = -1;
        session->next = sessions;
        sessions = session;
        session_count++;
        pthread_t thread;
        int error = pthread_create(&thread, NULL, session_thread, session);
        if (error) {
            sessions = session->next;
            session_count--;
            close(client);
            free(session);
        } else {
            pthread_detach(thread);
        }
        pthread_mutex_unlock(&sessions_lock);
    }
    return NULL;
}

static void stop_listener(void) {
    if (listener_fd < 0) return;
    char byte = 0;
    write(wake_pipe[1], &byte, 1);
    pthread_join(listener_tid, NULL);
    close(listener_fd);
    close(wake_pipe[0]);
    close(wake_pipe[1]);
    listener_fd = -1;
    active_port = 0;
    pthread_mutex_lock(&sessions_lock);
    for (struct session *session = sessions; session; session = session->next) {
        session->cancelled = true;
        shutdown(session->client, SHUT_RDWR);
        if (session->target >= 0) shutdown(session->target, SHUT_RDWR);
    }
    pthread_mutex_unlock(&sessions_lock);
}

int vp_socks5_set_port(uint16_t port) {
    pthread_mutex_lock(&configuration_lock);
    if (port == active_port) {
        pthread_mutex_unlock(&configuration_lock);
        return 0;
    }
    if (!port) {
        stop_listener();
        pthread_mutex_unlock(&configuration_lock);
        return 0;
    }
    int socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    int pipes[2] = {-1, -1};
    int error = socket_fd < 0 ? errno : 0;
    int one = 1;
    if (!error) {
        setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in address = {
            .sin_len = sizeof(address), .sin_family = AF_INET,
            .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)
        };
        if (bind(socket_fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
            listen(socket_fd, 128) < 0 || pipe(pipes) < 0) error = errno;
    }
    if (error) {
        if (socket_fd >= 0) close(socket_fd);
        pthread_mutex_unlock(&configuration_lock);
        return error;
    }
    // Bind the replacement before withdrawing the working listener.
    stop_listener();
    listener_fd = socket_fd;
    wake_pipe[0] = pipes[0];
    wake_pipe[1] = pipes[1];
    error = pthread_create(&listener_tid, NULL, listener_thread, NULL);
    if (error) {
        close(listener_fd);
        close(wake_pipe[0]);
        close(wake_pipe[1]);
        listener_fd = -1;
    } else {
        active_port = port;
    }
    pthread_mutex_unlock(&configuration_lock);
    return error;
}

uint16_t vp_socks5_port(void) {
    pthread_mutex_lock(&configuration_lock);
    uint16_t port = active_port;
    pthread_mutex_unlock(&configuration_lock);
    return port;
}

void vp_socks5_raise_fd_limit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return;
    rlim_t wanted = limit.rlim_max == RLIM_INFINITY || limit.rlim_max > OPEN_MAX
        ? OPEN_MAX : limit.rlim_max;
    if (wanted > limit.rlim_cur) {
        limit.rlim_cur = wanted;
        setrlimit(RLIMIT_NOFILE, &limit);
    }
}
