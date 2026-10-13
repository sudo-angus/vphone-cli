#pragma once
#include <stdint.h>
// 0 disables the service and cancels active sessions. Returns 0 or errno.
// Failed binds preserve the current listener. Calls are serialized internally.
int vp_socks5_set_port(uint16_t port);
uint16_t vp_socks5_port(void);
void vp_socks5_raise_fd_limit(void);
