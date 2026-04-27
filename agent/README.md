# HarmonyAgent v2 — Phase 2

Device-side input agent for low-latency touch injection and secure screen exploration.

## Protocol

Each frame is 8 bytes, little-endian:

```c
struct TouchFrame {
    uint8_t  cmd;      // Command type (see below)
    uint8_t  slot;     // Touch slot (0-9) or command-specific parameter
    uint16_t x;        // X coordinate or command-specific parameter
    uint16_t y;        // Y coordinate or command-specific parameter
    uint16_t reserved; // Pressure value for touch events
} __attribute__((packed));
```

### Commands

| cmd   | Name          | Description                                    |
|-------|---------------|------------------------------------------------|
| 0x01  | TOUCH_DOWN    | Finger down at (x, y), slot for multi-touch    |
| 0x02  | TOUCH_UP      | Finger up, slot for multi-touch release        |
| 0x03  | TOUCH_MOVE    | Finger move to (x, y), slot for multi-touch    |
| 0x04  | KEY           | Key press/release, x = key code                |
| 0x05  | PIN_CODE      | PIN digits packed in slot/x/y bytes            |
| 0x10  | SET_PROP      | Set uinput property bit (slot = bit number)    |
| 0x11  | OPEN_EVENT    | Switch to /dev/input/eventX mode              |
| 0x12  | LOG           | Request agent status log                       |
| 0x20  | GET_INFO      | Request agent info (mode, fd validity)         |
| 0x80  | PING          | Health check ping                              |
| 0x81  | PONG          | Health check response (8-byte frame)           |

### Touch Coordinates

Coordinates are normalized to 0-65535. The device-side agent maps them
to the actual screen resolution.

### Pressure

The `reserved` field is used as pressure value (0-255) for TOUCH_DOWN and
TOUCH_MOVE events. Default pressure is 50 if not specified.

### Multi-Touch

Use different `slot` values (0-9) for simultaneous touch points.
Each slot maintains its own tracking ID.

### PIN Code Input (cmd=0x05)

- `slot` = number of digits (max 4 per frame)
- Bytes encode BCD digits (0x0-0x9) packed into the frame
- Agent sends KEY_0 through KEY_9 with proper timing

### Secure Screen Experiments

**SET_PROP (0x10):** Dynamically set additional uinput device properties.
Some secure windows check input device properties. Setting properties like
`INPUT_PROP_DIRECT` (value 0) may allow events through security checks.

**OPEN_EVENT (0x11):** Switch from uinput to direct `/dev/input/eventX` mode.
- x=0: Auto-find the HarmonyAgent event device
- x=N: Open `/dev/input/eventN` directly
Direct event mode bypasses uinput and writes `input_event` structs to the
raw device node, which may have different security behavior.

**LOG (0x12):** Request current agent status as text.

**GET_INFO (0x20):** Returns 8-byte info frame with current mode (0=uinput, 1=direct)
and input fd validity.

## Health Check

- Mac sends PING (0x80) every 5 seconds
- Agent responds with PONG (0x81) as 8-byte frame
- If no PONG within 10 seconds, Mac considers agent dead and attempts reconnect

## Building

Requires a HarmonyOS/Linux aarch64 toolchain with Linux input headers:

```bash
# Example with aarch64-linux-gnu-gcc
aarch64-linux-gnu-gcc -o harmony_agent harmony_agent.c -static

# Or with HarmonyOS NDK
<path-to-ndk>/bin/clang --target=aarch64-linux-ohos -o harmony_agent harmony_agent.c
```

## Deployment

The Mac-side MirrorService auto-deploys the agent:
1. Checks if `harmony_agent` is already running on device
2. Pushes binary via `hdc file send` if needed
3. `chmod +x` and starts in background with `-v` (verbose)
4. Establishes `hdc fport` tunnel for TCP communication

Manual deployment:
```bash
hdc file send harmony_agent /data/local/tmp/harmony_agent
hdc shell chmod +x /data/local/tmp/harmony_agent
hdc shell "/data/local/tmp/harmony_agent -v &"
```

## Phase 1 vs Phase 2

| Feature              | Phase 1 | Phase 2 |
|---------------------|---------|---------|
| Basic touch          | Yes     | Yes     |
| Multi-touch (slots)  | Basic   | Full (pressure, touch_major) |
| Key events           | Basic   | Yes     |
| PIN code input       | No      | Yes     |
| INPUT_PROP_DIRECT    | No      | Yes     |
| Direct /dev/input    | No      | Yes     |
| Health check (ping)  | Text    | Binary frame |
| Auto-deploy          | No      | Yes     |
| Verbose logging      | No      | Yes (-v) |
