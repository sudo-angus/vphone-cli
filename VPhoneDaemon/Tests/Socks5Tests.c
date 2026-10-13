#include "../Native/Include/VphonedSocks5.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static uint16_t proxy_port;
static uint16_t tcp_port;
static uint16_t udp_port;
static void exact(int fd, void *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = read(fd, (char *)buffer + offset, count - offset);
        assert(n > 0);
        offset += (size_t)n;
    }
}
static int bound_socket(int type, uint16_t *port) {
    int fd = socket(AF_INET, type, 0);
    assert(fd >= 0);
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_ANY)};
    assert(bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(fd, (struct sockaddr *)&address, &length) == 0);
    *port = ntohs(address.sin_port);
    return fd;
}
static int connect_port(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    struct timeval timeout = {.tv_sec = 5};
    assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    return fd;
}
static void *echo_client(void *arg) {
    int fd = (int)(intptr_t)arg;
    char buffer[1024];
    ssize_t n;
    while ((n = read(fd, buffer, sizeof(buffer))) > 0) assert(write(fd, buffer, (size_t)n) == n);
    close(fd);
    return NULL;
}
static void *tcp_echo(void *arg) {
    int fd = (int)(intptr_t)arg;
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) break;
        pthread_t worker;
        assert(pthread_create(&worker, NULL, echo_client, (void *)(intptr_t)client) == 0);
        pthread_detach(worker);
    }
    return NULL;
}
static void *udp_echo(void *arg) {
    int fd = (int)(intptr_t)arg;
    for (;;) {
        char buffer[4096];
        struct sockaddr_storage source;
        socklen_t length = sizeof(source);
        ssize_t n = recvfrom(fd, buffer, sizeof(buffer), 0, (struct sockaddr *)&source, &length);
        if (n < 0) break;
        assert(sendto(fd, buffer, (size_t)n, 0, (struct sockaddr *)&source, length) == n);
    }
    return NULL;
}
static int greeting(void) {
    int fd = connect_port(proxy_port);
    const unsigned char hello[] = {5, 1, 0};
    // TCP segmentation must not affect framing.
    for (size_t i = 0; i < sizeof(hello); i++) assert(write(fd, hello + i, 1) == 1);
    unsigned char reply[2];
    exact(fd, reply, 2);
    assert(reply[0] == 5 && reply[1] == 0);
    return fd;
}
static void request(int fd, unsigned char command, uint16_t port, int domain, unsigned char reply[10]) {
    unsigned char packet[32] = {5, command, 0, domain ? 3 : 1};
    size_t length = 4;
    if (domain) {
        packet[length++] = 9;
        memcpy(packet + length, "localhost", 9);
        length += 9;
    } else {
        const unsigned char ip[4] = {127, 0, 0, 1};
        memcpy(packet + length, ip, 4);
        length += 4;
    }
    packet[length++] = port >> 8;
    packet[length++] = port & 255;
    assert(write(fd, packet, length) == (ssize_t)length);
    exact(fd, reply, 10);
    assert(reply[0] == 5);
}
static void *tcp_roundtrip(void *arg) {
    int fd = greeting();
    unsigned char reply[10];
    request(fd, 1, tcp_port, (int)(intptr_t)arg & 1, reply);
    assert(reply[1] == 0);
    const char payload[] = "guest-owned sockets: DNS, VPN routes, half-close";
    assert(write(fd, payload, sizeof(payload)) == sizeof(payload));
    assert(shutdown(fd, SHUT_WR) == 0);
    char received[sizeof(payload)];
    exact(fd, received, sizeof(received));
    assert(memcmp(received, payload, sizeof(payload)) == 0);
    char byte;
    assert(read(fd, &byte, 1) == 0);
    close(fd);
    return NULL;
}
static void udp_roundtrip(int domain) {
    int control = greeting();
    unsigned char reply[10];
    request(control, 3, 0, 0, reply);
    assert(reply[1] == 0 && reply[3] == 1);
    struct sockaddr_in relay = {.sin_len = sizeof(relay), .sin_family = AF_INET};
    memcpy(&relay.sin_addr, reply + 4, 4);
    memcpy(&relay.sin_port, reply + 8, 2);
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    struct timeval timeout = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    assert(connect(fd, (struct sockaddr *)&relay, sizeof(relay)) == 0);
    unsigned char packet[64] = {0, 0, 0, domain ? 3 : 1};
    size_t length = 4;
    if (domain) {
        packet[length++] = 9;
        memcpy(packet + length, "localhost", 9);
        length += 9;
    } else {
        const unsigned char ip[] = {127, 0, 0, 1};
        memcpy(packet + length, ip, 4);
        length += 4;
    }
    packet[length++] = udp_port >> 8;
    packet[length++] = udp_port & 255;
    memcpy(packet + length, "udp-echo", 8);
    length += 8;
    assert(write(fd, packet, length) == (ssize_t)length);
    unsigned char received[64];
    ssize_t count = read(fd, received, sizeof(received));
    assert(count == 18 && received[3] == 1);
    assert(memcmp(received + 10, "udp-echo", 8) == 0);
    close(fd);
    close(control);
}
int main(void) {
    vp_socks5_raise_fd_limit();
    int tcp = bound_socket(SOCK_STREAM, &tcp_port);
    assert(listen(tcp, 128) == 0);
    int udp = bound_socket(SOCK_DGRAM, &udp_port);
    pthread_t tcp_thread, udp_thread;
    assert(pthread_create(&tcp_thread, NULL, tcp_echo, (void *)(intptr_t)tcp) == 0);
    assert(pthread_create(&udp_thread, NULL, udp_echo, (void *)(intptr_t)udp) == 0);
    int reservation = bound_socket(SOCK_STREAM, &proxy_port);
    close(reservation);
    assert(vp_socks5_set_port(proxy_port) == 0);
    assert(vp_socks5_set_port(proxy_port) == 0);
    assert(vp_socks5_port() == proxy_port);
    // An unavailable replacement port must preserve the existing listener.
    assert(vp_socks5_set_port(tcp_port) == EADDRINUSE);
    assert(vp_socks5_port() == proxy_port);
    tcp_roundtrip((void *)0);
    tcp_roundtrip((void *)1);
    udp_roundtrip(0);
    udp_roundtrip(1);
    int bad = connect_port(proxy_port);
    unsigned char no_auth[] = {5, 1, 2}, answer[2];
    assert(write(bad, no_auth, sizeof(no_auth)) == sizeof(no_auth));
    exact(bad, answer, 2);
    assert(answer[1] == 255);
    close(bad);
    bad = greeting();
    unsigned char response[10];
    request(bad, 2, tcp_port, 0, response);
    assert(response[1] == 7);
    close(bad);
    pthread_t clients[64];
    for (int i = 0; i < 64; i++) assert(pthread_create(&clients[i], NULL, tcp_roundtrip, (void *)(intptr_t)i) == 0);
    for (int i = 0; i < 64; i++) pthread_join(clients[i], NULL);
    int idle = greeting();
    assert(vp_socks5_set_port(0) == 0);
    char byte;
    assert(read(idle, &byte, 1) <= 0);
    close(idle);
    assert(vp_socks5_port() == 0);
    for (int i = 0; i < 30; i++) {
        assert(vp_socks5_set_port(proxy_port) == 0);
        int client = greeting();
        assert(vp_socks5_set_port(0) == 0);
        close(client);
    }
    puts("PASS SOCKS5: TCP/domain/half-close, UDP/domain, auth negotiation, unsupported command, 64 concurrent clients, bind rollback, session cancellation, 30 restart cycles");
    // Echo threads are process-local test fixtures; process exit reaps them.
    return 0;
}
