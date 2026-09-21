#include "KrunVMMIPC.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct krun_vmm_request {
    uint32_t opcode;
    uint32_t port;
};

static int32_t neg_errno(void) {
    return errno == 0 ? -EIO : -errno;
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int send_flags(void) {
#ifdef MSG_NOSIGNAL
    return MSG_NOSIGNAL;
#else
    return 0;
#endif
}

int32_t krun_vmm_ipc_socketpair(int32_t fds[2]) {
    if (fds == NULL) {
        return -EINVAL;
    }

    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, pair) < 0) {
        return neg_errno();
    }

#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0 ||
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
        int saved = errno;
        close(pair[0]);
        close(pair[1]);
        errno = saved;
        return neg_errno();
    }
#endif

    if (set_cloexec(pair[0]) < 0 || set_cloexec(pair[1]) < 0) {
        int saved = errno;
        close(pair[0]);
        close(pair[1]);
        errno = saved;
        return neg_errno();
    }

    fds[0] = pair[0];
    fds[1] = pair[1];
    return 0;
}

int32_t krun_vmm_ipc_send_request(int32_t fd, uint32_t opcode, uint32_t port) {
    struct krun_vmm_request request = {
        .opcode = htonl(opcode),
        .port = htonl(port),
    };
    ssize_t written = send(fd, &request, sizeof(request), send_flags());
    if (written < 0) {
        return neg_errno();
    }
    return written == (ssize_t)sizeof(request) ? 0 : -EIO;
}

int32_t krun_vmm_ipc_recv_request(int32_t fd, uint32_t *opcode, uint32_t *port) {
    if (opcode == NULL || port == NULL) {
        return -EINVAL;
    }

    struct krun_vmm_request request;
    ssize_t received = recv(fd, &request, sizeof(request), 0);
    if (received < 0) {
        return neg_errno();
    }
    if (received == 0) {
        return 0;
    }
    if (received != (ssize_t)sizeof(request)) {
        return -EPROTO;
    }

    *opcode = ntohl(request.opcode);
    *port = ntohl(request.port);
    return 1;
}

int32_t krun_vmm_ipc_send_response(int32_t fd, int32_t status, int32_t passed_fd) {
    uint32_t wire_status = htonl((uint32_t)status);
    struct iovec iov = {
        .iov_base = &wire_status,
        .iov_len = sizeof(wire_status),
    };
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;

    char control[CMSG_SPACE(sizeof(int))];
    if (passed_fd >= 0) {
        memset(control, 0, sizeof(control));
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &passed_fd, sizeof(passed_fd));
    }

    ssize_t written = sendmsg(fd, &message, send_flags());
    if (written < 0) {
        return neg_errno();
    }
    return written == (ssize_t)sizeof(wire_status) ? 0 : -EIO;
}

int32_t krun_vmm_ipc_recv_response(int32_t fd, int32_t *status, int32_t *passed_fd) {
    if (status == NULL || passed_fd == NULL) {
        return -EINVAL;
    }

    uint32_t wire_status = 0;
    struct iovec iov = {
        .iov_base = &wire_status,
        .iov_len = sizeof(wire_status),
    };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t received = recvmsg(fd, &message, 0);
    if (received < 0) {
        return neg_errno();
    }
    if (received == 0) {
        return -ECONNRESET;
    }
    if (received != (ssize_t)sizeof(wire_status)) {
        return -EPROTO;
    }

    int received_fd = -1;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
            continue;
        }
        size_t payload = header->cmsg_len - CMSG_LEN(0);
        size_t count = payload / sizeof(int);
        int *descriptors = (int *)CMSG_DATA(header);
        for (size_t index = 0; index < count; index++) {
            if (received_fd < 0) {
                received_fd = descriptors[index];
            } else {
                close(descriptors[index]);
            }
        }
    }

    if ((message.msg_flags & MSG_CTRUNC) != 0) {
        if (received_fd >= 0) {
            close(received_fd);
        }
        return -EMSGSIZE;
    }

    int32_t decoded_status = (int32_t)ntohl(wire_status);
    if (decoded_status == 0 && received_fd < 0) {
        return -EPROTO;
    }
    if (decoded_status != 0 && received_fd >= 0) {
        close(received_fd);
        received_fd = -1;
    }

    *status = decoded_status;
    *passed_fd = received_fd;
    return 0;
}
