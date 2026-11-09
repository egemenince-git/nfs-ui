#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int write_all(int fd, const void *buffer, size_t length) {
    const char *bytes = buffer;
    while (length > 0) {
        ssize_t count = write(fd, bytes, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        length -= (size_t)count;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *path = getenv("NFS_CONNECT_ASKPASS_SOCKET");
    if (!path || !*path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fputs("NFS Connect SSH askpass socket is unavailable.\n", stderr);
        return 2;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 3;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);

    socklen_t address_length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&address, address_length) != 0) {
        close(fd);
        return 4;
    }

    const char *prompt = argc > 1 ? argv[1] : "";
    if (write_all(fd, prompt, strlen(prompt)) != 0 || write_all(fd, "\n", 1) != 0) {
        close(fd);
        return 5;
    }
    shutdown(fd, SHUT_WR);

    char buffer[1024];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { close(fd); return 6; }
        if (count == 0) break;
        if (write_all(STDOUT_FILENO, buffer, (size_t)count) != 0) {
            close(fd);
            return 7;
        }
    }

    close(fd);
    return 0;
}
