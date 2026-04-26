#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path


DEV_ECO_APP = Path("/Applications/DevEco_Testing_for_App.app")
HDC_CANDIDATES = [
    Path("/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"),
    DEV_ECO_APP / "Contents/Resources/app/resources/bin/hdc",
]
PY_SITE = DEV_ECO_APP / "Contents/Python/lib/python3.10/site-packages"
CASTING_SOCKET = "scrcpy_grpc_socket"
REMOTE_CASTING_SO = "/data/local/tmp/libscreen_casting.z.so"
CASTING_PROCESS_MARKER = "libscreen_casting.z.so"
LOG_FILE = Path("/tmp/DevecoCastMac-bridge.log")

# Shared state for broadcasting frames to all connected TCP clients.
# Protected by clients_lock.
clients: list[socket.socket] = []
clients_lock = threading.Lock()

# Optional frame buffer so newly-connected clients get a few recent frames
# (helps decoder init when they missed SPS/PPS).
FRAME_BUFFER_SIZE = 60
frame_buffer: collections.deque[bytes] = collections.deque(maxlen=FRAME_BUFFER_SIZE)
frame_buffer_lock = threading.Lock()
last_client_activity = time.monotonic()
last_client_activity_lock = threading.Lock()


def log(message: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}\n")
    except Exception:
        pass
    print(message, flush=True)


def mark_client_activity() -> None:
    global last_client_activity
    with last_client_activity_lock:
        last_client_activity = time.monotonic()


def seconds_since_client_activity() -> float:
    with last_client_activity_lock:
        return time.monotonic() - last_client_activity


def parent_is_alive(parent_pid: int | None) -> bool:
    if not parent_pid:
        return True
    try:
        os.kill(parent_pid, 0)
        return True
    except OSError:
        return False


def disable_local_proxy_for_grpc() -> None:
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        os.environ.pop(key, None)
    os.environ["NO_PROXY"] = "127.0.0.1,localhost"


def find_hdc(explicit: str | None) -> str:
    if explicit and os.access(explicit, os.X_OK):
        return explicit
    for path in HDC_CANDIDATES:
        if os.access(path, os.X_OK):
            return str(path)
    raise SystemExit("hdc not found")


def run(cmd: list[str], *, check: bool = True, timeout: float = 15) -> str:
    log("+ " + " ".join(cmd))
    proc = subprocess.run(
        cmd,
        check=False,
        timeout=timeout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = proc.stdout or ""
    if output.strip():
        log(output.rstrip())
    if check and proc.returncode != 0:
        raise SystemExit(f"command failed ({proc.returncode}): {' '.join(cmd)}")
    return output


def hdc(hdc_path: str, args: list[str], serial: str | None = None, *, check: bool = True, timeout: float = 15) -> str:
    cmd = [hdc_path]
    if serial:
        cmd += ["-t", serial]
    cmd += args
    return run(cmd, check=check, timeout=timeout)


def is_tcp_serial(serial: str) -> bool:
    return ":" in serial and not serial.startswith("/")


def hdc_target_connected(hdc_path: str, serial: str) -> bool:
    output = hdc(hdc_path, ["list", "targets", "-v"], check=False, timeout=5)
    for line in output.splitlines():
        columns = line.split()
        if len(columns) >= 3 and columns[0] == serial:
            return columns[2] == "Connected"
    return False


def reconnect_hdc_target(hdc_path: str, serial: str) -> None:
    if not is_tcp_serial(serial):
        return
    if hdc_target_connected(hdc_path, serial):
        return
    log(f"reconnecting hdc tcp target {serial}")
    hdc(hdc_path, ["tconn", serial, "-remove"], check=False, timeout=5)
    output = hdc(hdc_path, ["tconn", serial], check=False, timeout=10)
    if "[Fail]" in output or "Connect OK" not in output:
        raise RuntimeError(f"failed to reconnect hdc tcp target {serial}: {output.strip()}")
    validate = hdc(hdc_path, ["shell", "echo ok"], serial=serial, check=False, timeout=10)
    if "ok" not in validate:
        raise RuntimeError(f"hdc tcp target {serial} did not validate after reconnect: {validate.strip()}")


def ensure_casting_service(hdc_path: str, serial: str, remote_port: int, force_restart: bool = False) -> None:
    reconnect_hdc_target(hdc_path, serial)

    proc = hdc(
        hdc_path,
        ["shell", f"ps -ef | grep {CASTING_PROCESS_MARKER} | grep -v grep"],
        serial=serial,
        check=False,
    )
    already_running = CASTING_PROCESS_MARKER in proc

    if already_running and not force_restart:
        log("casting service already running, reusing")
        return

    if already_running and force_restart:
        log("force restarting casting service")
        for line in proc.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 2 and CASTING_PROCESS_MARKER in line:
                try:
                    pid = int(parts[1])
                    hdc(hdc_path, ["shell", f"kill -9 {pid}"], serial=serial, check=False)
                    log(f"killed old casting pid {pid}")
                    time.sleep(0.5)
                except ValueError:
                    pass

    ls_output = hdc(hdc_path, ["shell", f"ls -l {REMOTE_CASTING_SO}"], serial=serial, check=False)
    if "[Fail]" in ls_output:
        raise RuntimeError(ls_output.strip())
    if REMOTE_CASTING_SO not in ls_output:
        raise SystemExit(
            "libscreen_casting.z.so is not on the device. Open DevEco Testing projection once, then retry."
        )

    command = (
        "/system/bin/uitest start-daemon singleness "
        "--extension-name libscreen_casting.z.so "
        f"-scale 1 -frameRate 60 -bitRate 31457280 -p {remote_port} "
        "-screenId 0 -encodeType 0 -iFrameInterval 2000 -repeatInterval 33"
    )
    hdc(hdc_path, ["shell", command], serial=serial, check=False, timeout=8)
    time.sleep(1)

    proc = hdc(
        hdc_path,
        ["shell", f"ps -ef | grep {CASTING_PROCESS_MARKER} | grep -v grep"],
        serial=serial,
        check=False,
    )
    if CASTING_PROCESS_MARKER not in proc:
        raise SystemExit("failed to start libscreen_casting.z.so")


def forward_socket(hdc_path: str, serial: str, local_grpc_port: int, remote_port: int, socket_name: str) -> str:
    reconnect_hdc_target(hdc_path, serial)

    local = f"tcp:{local_grpc_port}"
    candidates = [
        ("unix", f"localabstract:{socket_name}"),
        ("tcp", f"tcp:{remote_port}"),
    ]
    last_error: str | None = None

    # Check if desired forward already exists before touching anything.
    list_output = hdc(hdc_path, ["fport", "ls"], serial=serial, check=False)
    for transport, remote in candidates:
        for line in list_output.splitlines():
            if f"tcp:{local_grpc_port}" not in line or remote not in line:
                continue
            columns = line.split()
            owner = columns[0] if columns else ""
            if owner == serial:
                log(f"forward {local} -> {remote} already exists for {serial}, reusing")
                return transport
            log(f"forward {local} -> {remote} belongs to {owner}, rebuilding for {serial}")
            hdc(hdc_path, ["fport", "rm", local, remote], check=False)

    # Only remove stale forwards if we need to create new ones.
    for _transport, remote in candidates:
        hdc(hdc_path, ["fport", "rm", local, remote], check=False)
        hdc(hdc_path, ["fport", "rm", local, remote], serial=serial, check=False)

    for transport, remote in candidates:
        output = hdc(hdc_path, ["fport", local, remote], serial=serial, check=False)
        if "[Fail]" in output or "failed" in output.lower():
            last_error = output.strip()
            log(f"forward {local} -> {remote} failed: {last_error}")
            continue
        log(f"forwarded {local} -> {remote}")
        return transport

    raise SystemExit(f"failed to forward gRPC port: {last_error}")


def cleanup_forward(hdc_path: str, serial: str, local_grpc_port: int, remote_port: int, socket_name: str) -> None:
    local = f"tcp:{local_grpc_port}"
    for remote in (f"localabstract:{socket_name}", f"tcp:{remote_port}"):
        hdc(hdc_path, ["fport", "rm", local, remote], serial=serial, check=False, timeout=5)
        hdc(hdc_path, ["fport", "rm", local, remote], check=False, timeout=5)


def broadcast_frame(frame: bytes) -> None:
    """Send frame to all connected TCP clients, removing dead ones."""
    dead: list[socket.socket] = []
    with clients_lock:
        for client in clients:
            try:
                client.sendall(frame)
            except (BrokenPipeError, ConnectionResetError, OSError, socket.timeout):
                dead.append(client)
        for client in dead:
            clients.remove(client)
            try:
                client.close()
            except Exception:
                pass
        if dead:
            mark_client_activity()
            log(f"removed {len(dead)} dead client(s)")


def grpc_reader(
    local_grpc_port: int,
    hdc_path: str,
    serial: str,
    remote_port: int,
    socket_name: str,
    skip_device_setup: bool,
) -> None:
    """Maintain a single gRPC stream and broadcast frames to all TCP clients."""
    disable_local_proxy_for_grpc()
    sys.path.insert(0, str(PY_SITE))

    import grpc
    from devicetest.controllers.tools.recorder.proto import scrcpy_pb2, scrcpy_pb2_grpc

    consecutive_failures = 0

    while True:
        try:
            if is_tcp_serial(serial) and not skip_device_setup:
                try:
                    reconnect_hdc_target(hdc_path, serial)
                except Exception as exc:
                    log(f"hdc tcp reconnect failed: {exc}")
                    consecutive_failures += 1
                    time.sleep(2)
                    continue

            # If we've failed multiple times, restart the casting service and forward.
            if consecutive_failures >= 2 and not skip_device_setup:
                log("too many gRPC failures, force restarting casting service and forward")
                try:
                    ensure_casting_service(hdc_path, serial, remote_port, force_restart=True)
                    forward_socket(hdc_path, serial, local_grpc_port, remote_port, socket_name)
                except Exception as exc:
                    log(f"failed to restart casting service: {exc}")
                consecutive_failures = 0

            channel = grpc.insecure_channel(
                f"127.0.0.1:{local_grpc_port}",
                options=[
                    ("grpc.max_receive_message_length", 64 * 1024 * 1024),
                ],
            )
            log("waiting for gRPC channel to be ready...")
            grpc.channel_ready_future(channel).result(timeout=30)
            log("gRPC channel ready")

            stub = scrcpy_pb2_grpc.ScrcpyServiceStub(channel)

            # Try to stop any previous stream so the service can accept a new onStart.
            try:
                log("calling onStop to clean up previous stream")
                stub.onStop(scrcpy_pb2.Empty(), timeout=5)
                log("onStop succeeded")
            except Exception as exc:
                log(f"onStop failed (harmless): {exc}")

            # Retry onStart with exponential backoff.
            responses = None
            for attempt in range(1, 6):
                try:
                    log(f"calling onStart (attempt {attempt}/5, no timeout)")
                    # No timeout for the streaming RPC so it can run indefinitely.
                    responses = stub.onStart(scrcpy_pb2.Empty(), timeout=None)
                    break
                except grpc.RpcError as exc:
                    code = exc.code() if hasattr(exc, "code") else None
                    log(f"onStart failed (attempt {attempt}/5): {exc} code={code}")
                    if attempt == 5:
                        raise
                    wait = min(2 ** attempt, 16)
                    log(f"retrying onStart in {wait}s...")
                    time.sleep(wait)
                except Exception as exc:
                    log(f"onStart unexpected error (attempt {attempt}/5): {exc}")
                    if attempt == 5:
                        raise
                    time.sleep(2)

            log("onStart stream established")
            had_client = False
            seen = 0
            sent = 0
            drop_log_counter = 0
            last_frame_time = time.monotonic()

            for response in responses:
                seen += 1
                now = time.monotonic()
                last_frame_time = now

                if seen <= 20:
                    payload_keys = list(getattr(response, "payload", {}).keys())
                    data_value = response.payload.get("data")
                    payload_data_len = len(data_value.val_bytes) if data_value is not None and data_value.HasField("val_bytes") else 0
                    log(
                        "gRPC response "
                        f"#{seen}: reply_type={getattr(response, 'reply_type', 'N/A')} "
                        f"top_data_len={len(getattr(response, 'data', b''))} "
                        f"payload_data_len={payload_data_len} "
                        f"payload_keys={payload_keys}"
                    )

                payload = response.payload
                data_value = payload.get("data")
                if data_value is not None and data_value.HasField("val_bytes"):
                    h264 = data_value.val_bytes
                else:
                    raw_data = getattr(response, "data", b"")
                    if isinstance(raw_data, str):
                        raw_data = raw_data.encode("utf-8")
                    h264 = raw_data

                if not h264:
                    continue

                flags_value = payload.get("flags")
                pts_value = payload.get("pts")
                flags = int(flags_value.val_int) if flags_value is not None and flags_value.HasField("val_int") else 0
                pts = int(pts_value.val_int) if pts_value is not None and pts_value.HasField("val_int") else time.monotonic_ns() // 1000

                packet_len = 1 + 8 + len(h264)
                frame = struct.pack(">IBq", packet_len, flags & 0xFF, pts) + h264

                # Buffer recent frames for newly-connected clients.
                with frame_buffer_lock:
                    frame_buffer.append(frame)

                with clients_lock:
                    current_has_client = len(clients) > 0

                # Request an IDR frame the moment the first client appears.
                if current_has_client and not had_client:
                    try:
                        log("requesting IDR frame for new client")
                        stub.onRequestIDRFrame(scrcpy_pb2.Empty(), timeout=5)
                        log("IDR request sent")
                    except Exception as exc:
                        log(f"IDR request failed: {exc}")

                had_client = current_has_client

                if current_has_client:
                    broadcast_frame(frame)
                    sent += 1
                    if sent <= 5:
                        log(f"sent frame #{sent}: bytes={len(h264)} flags={flags & 0xFF} pts={pts}")
                    if sent % 60 == 0:
                        log(f"sent {sent} frames total")
                else:
                    drop_log_counter += 1
                    if drop_log_counter % 300 == 0:
                        log(f"dropping frame (no clients), size={len(h264)}")

            log(f"gRPC stream ended cleanly: seen={seen} sent={sent}")
            consecutive_failures = 0

        except Exception as exc:
            log(f"gRPC reader error: {exc}")
            consecutive_failures += 1

        log("gRPC reader will restart in 2s...")
        time.sleep(2)


def accept_clients(server: socket.socket, bridge_port: int) -> None:
    """Accept incoming TCP connections and add them to the broadcast list."""
    while True:
        try:
            client, addr = server.accept()
            log(f"client connected: {addr}")
            try:
                client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                client.settimeout(10.0)
            except Exception as exc:
                log(f"failed to configure client socket: {exc}")

            # Send buffered frames so the decoder gets recent SPS/PPS/key-frame data.
            with frame_buffer_lock:
                buffered = list(frame_buffer)
            try:
                for frame in buffered:
                    client.sendall(frame)
            except (BrokenPipeError, ConnectionResetError, OSError, socket.timeout):
                log(f"client {addr} died during buffered frame burst")
                try:
                    client.close()
                except Exception:
                    pass
                continue

            with clients_lock:
                clients.append(client)
            mark_client_activity()
            log(f"client {addr} ready ({len(buffered)} buffered frames flushed)")
        except OSError as exc:
            log(f"accept error: {exc}")
            break


def serve(args: argparse.Namespace) -> None:
    hdc_path = find_hdc(args.hdc)
    shutting_down = False
    server: socket.socket | None = None

    def shutdown(_signum: int | None = None, _frame: object | None = None) -> None:
        nonlocal shutting_down
        if shutting_down:
            return
        shutting_down = True
        log("shutting down")
        if server is not None:
            try:
                server.close()
            except Exception:
                pass
        with clients_lock:
            for client in clients:
                try:
                    client.close()
                except Exception:
                    pass
            clients.clear()
        cleanup_forward(hdc_path, args.serial, args.grpc_port, args.remote_port, args.socket_name)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    if args.skip_device_setup:
        transport = "preconfigured"
        log("using preconfigured device setup")
    else:
        ensure_casting_service(hdc_path, args.serial, args.remote_port, force_restart=True)
        transport = forward_socket(hdc_path, args.serial, args.grpc_port, args.remote_port, args.socket_name)
    log(f"using {transport} transport for casting stream")

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.bridge_port))
    server.listen(5)
    log(f"bridge listening on 127.0.0.1:{args.bridge_port}")

    grpc_thread = threading.Thread(
        target=grpc_reader,
        args=(args.grpc_port, hdc_path, args.serial, args.remote_port, args.socket_name, args.skip_device_setup),
        daemon=True,
        name="grpc-reader",
    )
    grpc_thread.start()

    accept_thread = threading.Thread(
        target=accept_clients,
        args=(server, args.bridge_port),
        daemon=True,
        name="accept-clients",
    )
    accept_thread.start()

    # Keep main thread alive so the daemon threads keep running.
    try:
        while True:
            time.sleep(1)
            if not parent_is_alive(args.parent_pid):
                log(f"parent process {args.parent_pid} is gone; exiting bridge")
                shutdown()
            if args.idle_timeout > 0:
                with clients_lock:
                    has_clients = len(clients) > 0
                if not has_clients and seconds_since_client_activity() > args.idle_timeout:
                    log(f"no clients for {args.idle_timeout:.0f}s; exiting bridge")
                    shutdown()
            if not grpc_thread.is_alive():
                log("gRPC thread died, restarting...")
                grpc_thread = threading.Thread(
                    target=grpc_reader,
                    args=(args.grpc_port, hdc_path, args.serial, args.remote_port, args.socket_name, args.skip_device_setup),
                    daemon=True,
                    name="grpc-reader",
                )
                grpc_thread.start()
    except KeyboardInterrupt:
        pass
    finally:
        shutdown()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    parser.add_argument("--hdc")
    parser.add_argument("--grpc-port", type=int, default=9510)
    parser.add_argument("--bridge-port", type=int, default=18180)
    parser.add_argument("--remote-port", type=int, default=8710)
    parser.add_argument("--socket-name", default=CASTING_SOCKET)
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--idle-timeout", type=float, default=0)
    parser.add_argument("--skip-device-setup", action="store_true")
    args = parser.parse_args()
    serve(args)


if __name__ == "__main__":
    main()
