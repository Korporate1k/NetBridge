#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef enum Tun2proxyVerbosity {
  Tun2proxyVerbosity_Off = 0,
  Tun2proxyVerbosity_Error,
  Tun2proxyVerbosity_Warn,
  Tun2proxyVerbosity_Info,
  Tun2proxyVerbosity_Debug,
  Tun2proxyVerbosity_Trace,
} Tun2proxyVerbosity;

typedef struct Tun2proxyTrafficStatus {
  uint64_t tx;
  uint64_t rx;
} Tun2proxyTrafficStatus;









#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * # Safety
 *
 * set dump log info callback.
 */
void tun2proxy_set_log_callback(void (*callback)(enum Tun2proxyVerbosity, const char*, void*),
                                void *ctx);

/**
 * # Safety
 * Run the tun2proxy component with command line arguments
 * Parameters:
 * - cli_args: The command line arguments,
 *   e.g. `tun2proxy-bin --setup --proxy socks5://127.0.0.1:1080 --bypass 98.76.54.0/24 --dns over-tcp --verbosity trace`
 * - tun_mtu: The MTU of the TUN device, e.g. 1500
 * - packet_information: Whether exists packet information in packet from TUN device
 */
int tun2proxy_run_with_cli_args(const char *cli_args,
                                unsigned short tun_mtu,
                                bool packet_information);

/**
 * # Safety
 *
 * Shutdown the tun2proxy component.
 */
int tun2proxy_stop(void);

/**
 * # Safety
 *
 * set traffic status callback.
 */
void tun2proxy_set_traffic_status_callback(uint32_t send_interval_secs,
                                           void (*callback)(const struct Tun2proxyTrafficStatus*,
                                                            void*),
                                           void *ctx);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus
