#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define AGENT_PORT 8711
#define FRAME_SIZE 8
#define ABS_MAX 65535

enum {
    CMD_TOUCH_DOWN = 0x01,
    CMD_TOUCH_UP = 0x02,
    CMD_TOUCH_MOVE = 0x03,
    CMD_KEY = 0x04,
    CMD_PING = 0x7f
};

static volatile int g_running = 1;

static void handle_signal(int signo) {
    (void)signo;
    g_running = 0;
}

static int emit_event(int fd, int type, int code, int value) {
    struct input_event event;
    memset(&event, 0, sizeof(event));
    gettimeofday(&event.time, NULL);
    event.type = type;
    event.code = code;
    event.value = value;
    return write(fd, &event, sizeof(event)) == (ssize_t)sizeof(event) ? 0 : -1;
}

static void sync_event(int fd) {
    emit_event(fd, EV_SYN, SYN_REPORT, 0);
}

static int open_uinput(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open /dev/uinput");
        return -1;
    }

    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);

    struct uinput_user_dev dev;
    memset(&dev, 0, sizeof(dev));
    snprintf(dev.name, UINPUT_MAX_NAME_SIZE, "HarmonyAgent Touch");
    dev.id.bustype = BUS_VIRTUAL;
    dev.id.vendor = 0x18d1;
    dev.id.product = 0x0001;
    dev.id.version = 1;
    dev.absmin[ABS_MT_SLOT] = 0;
    dev.absmax[ABS_MT_SLOT] = 9;
    dev.absmin[ABS_MT_TRACKING_ID] = 0;
    dev.absmax[ABS_MT_TRACKING_ID] = 65535;
    dev.absmin[ABS_MT_POSITION_X] = 0;
    dev.absmax[ABS_MT_POSITION_X] = ABS_MAX;
    dev.absmin[ABS_MT_POSITION_Y] = 0;
    dev.absmax[ABS_MT_POSITION_Y] = ABS_MAX;

    if (write(fd, &dev, sizeof(dev)) != (ssize_t)sizeof(dev)) {
        perror("write uinput_user_dev");
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return -1;
    }
    usleep(100000);
    return fd;
}

static void close_uinput(int fd) {
    if (fd >= 0) {
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
    }
}

static uint16_t read_le16(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static void send_touch(int fd, uint8_t cmd, uint8_t slot, uint16_t x, uint16_t y) {
    static int tracking_id = 1;
    emit_event(fd, EV_ABS, ABS_MT_SLOT, slot);
    if (cmd == CMD_TOUCH_DOWN) {
        emit_event(fd, EV_KEY, BTN_TOUCH, 1);
        emit_event(fd, EV_ABS, ABS_MT_TRACKING_ID, tracking_id++);
    }
    emit_event(fd, EV_ABS, ABS_MT_POSITION_X, x);
    emit_event(fd, EV_ABS, ABS_MT_POSITION_Y, y);
    if (cmd == CMD_TOUCH_UP) {
        emit_event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
        emit_event(fd, EV_KEY, BTN_TOUCH, 0);
    }
    sync_event(fd);
}

static int read_exact(int fd, uint8_t *buffer, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = read(fd, buffer + offset, size - offset);
        if (n == 0) {
            return 0;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        offset += (size_t)n;
    }
    return 1;
}

static void handle_client(int client_fd, int input_fd) {
    uint8_t frame[FRAME_SIZE];
    while (g_running) {
        int result = read_exact(client_fd, frame, sizeof(frame));
        if (result <= 0) {
            break;
        }
        uint8_t cmd = frame[0];
        uint8_t slot = frame[1];
        uint16_t x = read_le16(&frame[2]);
        uint16_t y = read_le16(&frame[4]);
        switch (cmd) {
        case CMD_TOUCH_DOWN:
        case CMD_TOUCH_MOVE:
        case CMD_TOUCH_UP:
            send_touch(input_fd, cmd, slot, x, y);
            break;
        case CMD_KEY:
            emit_event(input_fd, EV_KEY, x, 1);
            sync_event(input_fd);
            emit_event(input_fd, EV_KEY, x, 0);
            sync_event(input_fd);
            break;
        case CMD_PING:
            write(client_fd, "PONG", 4);
            break;
        default:
            break;
        }
    }
}

int main(int argc, char **argv) {
    int port = AGENT_PORT;
    if (argc > 1) {
        port = atoi(argv[1]);
    }
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    int input_fd = open_uinput();
    if (input_fd < 0) {
        return 2;
    }

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        close_uinput(input_fd);
        return 3;
    }

    int reuse = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        close_uinput(input_fd);
        return 4;
    }
    if (listen(server_fd, 1) < 0) {
        perror("listen");
        close(server_fd);
        close_uinput(input_fd);
        return 5;
    }

    printf("HarmonyAgent listening on 127.0.0.1:%d\n", port);
    fflush(stdout);

    while (g_running) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            break;
        }
        handle_client(client_fd, input_fd);
        close(client_fd);
    }

    close(server_fd);
    close_uinput(input_fd);
    return 0;
}
