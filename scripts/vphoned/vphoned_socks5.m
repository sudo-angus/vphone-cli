#import "vphoned_socks5.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
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
