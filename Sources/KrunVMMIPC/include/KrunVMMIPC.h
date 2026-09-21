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

#ifdef __cplusplus
}
#endif

#endif
