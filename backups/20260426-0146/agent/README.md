# HarmonyAgent Phase 1

Device-side prototype for low-latency touch injection.

Protocol frame is 8 bytes, little-endian:

```c
struct TouchFrame {
    uint8_t cmd;      // 0x01 DOWN, 0x02 UP, 0x03 MOVE, 0x04 KEY, 0x7f PING
    uint8_t slot;     // touch slot
    uint16_t x;       // 0..65535 normalized absolute X
    uint16_t y;       // 0..65535 normalized absolute Y
    uint16_t reserved;
};
```

The prototype listens on device loopback port `8711`. The Mac side should use
`hdc fport tcp:<localPort> tcp:8711` and connect `AgentSocketClient` to the
forwarded local port.

Build requires a HarmonyOS/Linux aarch64 toolchain with Linux input headers.
This file is intentionally not built by the macOS Xcode target.
