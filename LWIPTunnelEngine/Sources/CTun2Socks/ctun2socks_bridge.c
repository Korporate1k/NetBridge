#include "ctun2socks_bridge.h"

#include <string.h>

/* Set by Swift (see `ctun2socks_output_handler` in the header). */
void (*ctun2socks_output_handler)(const uint8_t *data, size_t len) = 0;

void ctun2socks_output(const uint8_t *data, size_t len) {
    if (ctun2socks_output_handler) {
        ctun2socks_output_handler(data, len);
    }
}

void ctun2socks_start(const char *socks_server_addr, const char *username,
                      const char *password, int fd, int mtu) {
    /* Keep these in sync with `TunnelEngine.tunnelLocalAddress` /
       `tunnelGatewayAddress` on the Swift side. */
    static const char *netif_ipaddr = "10.0.0.2";
    static const char *netif_netmask = "255.255.255.0";

    char *argv[16];
    int argc = 0;
    argv[argc++] = (char *)"tun2socks";
    argv[argc++] = (char *)"--netif-ipaddr";   argv[argc++] = (char *)netif_ipaddr;
    argv[argc++] = (char *)"--netif-netmask";  argv[argc++] = (char *)netif_netmask;
    argv[argc++] = (char *)"--loglevel";       argv[argc++] = (char *)"none";
    argv[argc++] = (char *)"--socks-server-addr"; argv[argc++] = (char *)socks_server_addr;
    if (username && username[0] != '\0' && password) {
        argv[argc++] = (char *)"--username";   argv[argc++] = (char *)username;
        argv[argc++] = (char *)"--password";   argv[argc++] = (char *)password;
    }

    tun2socks_main(argc, argv, fd, mtu);
}
