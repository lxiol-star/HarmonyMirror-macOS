#include <arpa/inet.h>
#include <dirent.h>
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
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define AGENT_PORT 8711
#define FRAME_SIZE 8
#define ABS_MAX 65535

enum {
    CMD_TOUCH_DOWN = 0x01,
    CMD_TOUCH_UP   = 0x02,
    CMD_TOUCH_MOVE = 0x03,
    CMD_KEY        = 0x04,
    CMD_PIN_CODE   = 0x05,
    CMD_PING       = 0x80,
    CMD_PONG       = 0x81,
    CMD_SET_PROP   = 0x10,
    CMD_OPEN_EVENT = 0x11,
    CMD_LOG        = 0x12,
    CMD_GET_INFO   = 0x20
};

enum input_mode {
    MODE_UINPUT = 0,
    MODE_DIRECT_EVENT
};

static volatile int g_running = 1;
static int g_verbose = 0;

static void handle_signal(int signo) {
    (void)signo;
    g_running = 0;
}

static int64_t now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
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
    ioctl(fd, UI_SET_KEYBIT, BTN_TOOL_FINGER);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOOL_DOUBLETAP);

    ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_PRESSURE);
    ioctl(fd, UI_SET_ABSBIT, ABS_MT_TOUCH_MAJOR);

    /* Phase 2: INPUT_PROP_DIRECT — touchscreens set this property.
       Some secure windows check input device properties; setting DIRECT
       may allow touch events through. */
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    struct uinput_user_dev dev;
    memset(&dev, 0, sizeof(dev));
    snprintf(dev.name, UINPUT_MAX_NAME_SIZE, "HarmonyAgent Touch");
    dev.id.bustype = BUS_VIRTUAL;
    dev.id.vendor = 0x18d1;
    dev.id.product = 0x0001;
    dev.id.version = 2;

    dev.absmin[ABS_MT_SLOT] = 0;
    dev.absmax[ABS_MT_SLOT] = 9;
    dev.absmin[ABS_MT_TRACKING_ID] = 0;
    dev.absmax[ABS_MT_TRACKING_ID] = 65535;
    dev.absmin[ABS_MT_POSITION_X] = 0;
    dev.absmax[ABS_MT_POSITION_X] = ABS_MAX;
    dev.absmin[ABS_MT_POSITION_Y] = 0;
    dev.absmax[ABS_MT_POSITION_Y] = ABS_MAX;
    dev.absmin[ABS_MT_PRESSURE] = 0;
    dev.absmax[ABS_MT_PRESSURE] = 255;
    dev.absmin[ABS_MT_TOUCH_MAJOR] = 0;
    dev.absmax[ABS_MT_TOUCH_MAJOR] = 255;

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

    if (g_verbose) {
        printf("[%lld] uinput device created with INPUT_PROP_DIRECT\n", now_ms());
        fflush(stdout);
    }
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

static void send_touch(int input_fd, uint8_t cmd, uint8_t slot, uint16_t x, uint16_t y, uint16_t pressure) {
    static int tracking_ids[10] = {0};
    if (slot > 9) slot = 0;

    emit_event(input_fd, EV_ABS, ABS_MT_SLOT, slot);

    if (cmd == CMD_TOUCH_DOWN) {
        tracking_ids[slot] = (tracking_ids[slot] + 1) & 0x7FFF;
        if (tracking_ids[slot] == 0) tracking_ids[slot] = 1;
        emit_event(input_fd, EV_KEY, BTN_TOUCH, 1);
        emit_event(input_fd, EV_ABS, ABS_MT_TRACKING_ID, tracking_ids[slot]);
        emit_event(input_fd, EV_ABS, ABS_MT_PRESSURE, pressure > 0 ? pressure : 50);
        emit_event(input_fd, EV_ABS, ABS_MT_TOUCH_MAJOR, pressure > 0 ? pressure : 10);
    }

    emit_event(input_fd, EV_ABS, ABS_MT_POSITION_X, x);
    emit_event(input_fd, EV_ABS, ABS_MT_POSITION_Y, y);

    if (cmd == CMD_TOUCH_MOVE) {
        emit_event(input_fd, EV_ABS, ABS_MT_PRESSURE, pressure > 0 ? pressure : 50);
        emit_event(input_fd, EV_ABS, ABS_MT_TOUCH_MAJOR, pressure > 0 ? pressure : 10);
    }

    if (cmd == CMD_TOUCH_UP) {
        emit_event(input_fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
        emit_event(input_fd, EV_ABS, ABS_MT_PRESSURE, 0);
        emit_event(input_fd, EV_ABS, ABS_MT_TOUCH_MAJOR, 0);
        /* Check if all slots are up; release BTN_TOUCH */
        emit_event(input_fd, EV_KEY, BTN_TOUCH, 0);
    }

    sync_event(input_fd);
}

static void send_key_press(int input_fd, uint16_t key_code) {
    emit_event(input_fd, EV_KEY, key_code, 1);
    sync_event(input_fd);
    emit_event(input_fd, EV_KEY, key_code, 0);
    sync_event(input_fd);
}

static void send_pin_code(int input_fd, const uint8_t *digits, int count) {
    /* KEY_0 = 11, KEY_1 = 2, ..., KEY_9 = 10 */
    static const int key_map[] = {11, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    for (int i = 0; i < count && i < 16; i++) {
        int d = digits[i] & 0x0F;
        if (d > 9) continue;
        emit_event(input_fd, EV_KEY, key_map[d], 1);
        sync_event(input_fd);
        usleep(50000); /* 50ms between digits */
        emit_event(input_fd, EV_KEY, key_map[d], 0);
        sync_event(input_fd);
        usleep(30000); /* 30ms release gap */
    }
}

static int find_event_device(const char *name_substring) {
    /* Scan /dev/input/eventX for a device matching name_substring */
    DIR *dir = opendir("/dev/input");
    if (!dir) return -1;

    char path[256];
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (strncmp(ent->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        int fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) continue;

        char dev_name[256] = {0};
        if (ioctl(fd, EVIOCGNAME(sizeof(dev_name)), dev_name) >= 0) {
            if (strstr(dev_name, name_substring)) {
                closedir(dir);
                if (g_verbose) {
                    printf("[%lld] Found event device: %s -> %s\n", now_ms(), path, dev_name);
                    fflush(stdout);
                }
                return fd;
            }
        }
        close(fd);
    }
    closedir(dir);
    return -1;
}

static int read_exact(int fd, uint8_t *buffer, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = read(fd, buffer + offset, size - offset);
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)n;
    }
    return 1;
}

static void send_pong_frame(int client_fd) {
    uint8_t pong[FRAME_SIZE] = {CMD_PONG, 0, 0, 0, 0, 0, 0, 0};
    write(client_fd, pong, FRAME_SIZE);
}

static void send_info_response(int client_fd, int input_fd, int input_mode) {
    /* Send back a response frame with input_mode info */
    uint8_t info[FRAME_SIZE] = {CMD_GET_INFO, (uint8_t)input_mode, 0, 0, 0, 0, 0, 0};
    if (input_fd >= 0) info[2] = 1; /* input_fd valid */
    write(client_fd, info, FRAME_SIZE);
}

static void send_log_response(int client_fd, const char *msg) {
    /* Send log messages as newline-terminated text */
    if (msg && client_fd >= 0) {
        write(client_fd, msg, strlen(msg));
        write(client_fd, "\n", 1);
    }
}

static void handle_client(int client_fd, int uinput_fd) {
    int input_fd = uinput_fd;
    int input_mode = MODE_UINPUT;
    int direct_event_fd = -1;

    if (g_verbose) {
        printf("[%lld] Client connected\n", now_ms());
        fflush(stdout);
    }

    uint8_t frame[FRAME_SIZE];
    while (g_running) {
        int result = read_exact(client_fd, frame, sizeof(frame));
        if (result <= 0) break;

        uint8_t cmd = frame[0];
        uint8_t slot = frame[1];
        uint16_t x = read_le16(&frame[2]);
        uint16_t y = read_le16(&frame[4]);
        uint16_t reserved = read_le16(&frame[6]);

        switch (cmd) {
        case CMD_TOUCH_DOWN:
        case CMD_TOUCH_MOVE:
        case CMD_TOUCH_UP:
            send_touch(input_fd, cmd, slot, x, y, reserved);
            break;

        case CMD_KEY:
            send_key_press(input_fd, x);
            break;

        case CMD_PIN_CODE:
            /* slot = digit count, x/y packed as BCD digits */
            send_pin_code(input_fd, &frame[1], 2); /* first 2 bytes as digits */
            break;

        case CMD_PING:
            send_pong_frame(client_fd);
            break;

        case CMD_SET_PROP:
            /* Experimental: try setting additional input device properties.
               frame[1] = property bit to set.
               This is a no-op if the property is already set at creation. */
            if (input_mode == MODE_UINPUT && input_fd >= 0) {
                int prop = (int)frame[1];
                int rc = ioctl(input_fd, UI_SET_PROPBIT, prop);
                if (g_verbose) {
                    printf("[%lld] UI_SET_PROPBIT(%d) = %d (errno=%d)\n",
                           now_ms(), prop, rc, rc < 0 ? errno : 0);
                    fflush(stdout);
                }
            }
            break;

        case CMD_OPEN_EVENT: {
            /* Switch to direct /dev/input/eventX mode.
               x is a flag: 0 = find "HarmonyAgent" device, nonzero = /dev/input/eventN (N=x%100) */
            int new_fd;
            if (x == 0) {
                new_fd = find_event_device("HarmonyAgent");
            } else {
                char path[64];
                snprintf(path, sizeof(path), "/dev/input/event%d", x % 100);
                new_fd = open(path, O_RDWR | O_NONBLOCK);
                if (g_verbose) {
                    printf("[%lld] Open direct %s = %d (errno=%d)\n",
                           now_ms(), path, new_fd, new_fd < 0 ? errno : 0);
                    fflush(stdout);
                }
            }
            if (new_fd >= 0) {
                if (direct_event_fd >= 0 && direct_event_fd != uinput_fd) {
                    close(direct_event_fd);
                }
                direct_event_fd = new_fd;
                input_fd = new_fd;
                input_mode = MODE_DIRECT_EVENT;
                if (g_verbose) {
                    printf("[%lld] Switched to direct event mode, fd=%d\n", now_ms(), new_fd);
                    fflush(stdout);
                }
            } else {
                if (g_verbose) {
                    printf("[%lld] Direct event open failed, staying in uinput mode\n", now_ms());
                    fflush(stdout);
                }
            }
            break;
        }

        case CMD_LOG:
            /* Request: return current mode info as log text */
            {
                char buf[128];
                snprintf(buf, sizeof(buf), "mode=%s fd=%d",
                         input_mode == MODE_UINPUT ? "uinput" : "direct", input_fd);
                send_log_response(client_fd, buf);
            }
            break;

        case CMD_GET_INFO:
            send_info_response(client_fd, input_fd, input_mode);
            break;

        default:
            break;
        }
    }

    if (direct_event_fd >= 0 && direct_event_fd != uinput_fd) {
        close(direct_event_fd);
    }

    if (g_verbose) {
        printf("[%lld] Client disconnected\n", now_ms());
        fflush(stdout);
    }
}

static void print_usage(const char *prog) {
    printf("HarmonyAgent v2 — HarmonyOS device-side input agent\n");
    printf("Usage: %s [options] [port]\n", prog);
    printf("Options:\n");
    printf("  -v    Verbose logging\n");
    printf("  -h    Show this help\n");
    printf("Default port: %d\n", AGENT_PORT);
}

int main(int argc, char **argv) {
    int port = AGENT_PORT;
    int opt;

    while ((opt = getopt(argc, argv, "vh")) != -1) {
        switch (opt) {
        case 'v':
            g_verbose = 1;
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }
    if (optind < argc) {
        port = atoi(argv[optind]);
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("HarmonyAgent v2 starting on port %d\n", port);
    fflush(stdout);

    int input_fd = open_uinput();
    if (input_fd < 0) {
        return 2;
    }

    /* Log uinput creation for secure screen diagnostics */
    printf("[%lld] uinput fd=%d, INPUT_PROP_DIRECT set\n", now_ms(), input_fd);
    fflush(stdout);

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

    printf("HarmonyAgent v2 listening on 127.0.0.1:%d (verbose=%d)\n", port, g_verbose);
    fflush(stdout);

    while (g_running) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        handle_client(client_fd, input_fd);
        close(client_fd);
    }

    close(server_fd);
    close_uinput(input_fd);
    printf("HarmonyAgent v2 stopped\n");
    return 0;
}
