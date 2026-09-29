#ifndef KRUN_VMM_IPC_H
#define KRUN_VMM_IPC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t krun_vmm_ipc_socketpair(int32_t fds[2]);
int32_t krun_vmm_ipc_send_request(int32_t fd, uint32_t opcode, uint32_t port);
int32_t krun_vmm_ipc_recv_request(int32_t fd, uint32_t *opcode, uint32_t *port);
int32_t krun_vmm_ipc_send_response(int32_t fd, int32_t status, int32_t passed_fd);
int32_t krun_vmm_ipc_recv_response(int32_t fd, int32_t *status, int32_t *passed_fd);
int32_t krun_vmm_ipc_install_profile_signal_relay(
    int32_t *read_fd, int32_t snapshot_signal, int32_t reset_signal
);
int32_t krun_vmm_ipc_recv_profile_signal(int32_t fd, uint8_t *command);
int32_t krun_vmm_ipc_uninstall_profile_signal_relay(void);

#ifdef __cplusplus
}
#endif

#endif
