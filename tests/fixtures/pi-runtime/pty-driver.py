"""Isolated stdlib PTY bridge. JSONL start/input/resize/terminate, no shell.

The first record supplies absolute argv, cwd and the complete child environment.
Output records contain base64 bytes or the reaped child's exit status. Limits
apply to records, queued writes, runtime and cleanup, including orchestrator EOF.
"""
import base64
import errno
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

LIMIT = 1024 * 1024


def dimensions(fd, rows, cols):
    if not (isinstance(rows, int) and isinstance(cols, int) and 2 <= rows <= 200 and 10 <= cols <= 500):
        raise ValueError("invalid PTY dimensions")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    incoming = bytearray()
    deadline = time.monotonic() + 10
    while b"\n" not in incoming:
        if time.monotonic() >= deadline:
            raise TimeoutError("start record deadline")
        if select.select([0], [], [], 0.1)[0]:
            chunk = os.read(0, 65536)
            if not chunk:
                raise EOFError("missing start record")
            incoming.extend(chunk)
            if len(incoming) > LIMIT:
                raise ValueError("start record too large")
    line, _, rest = incoming.partition(b"\n")
    config = json.loads(line)
    argv, env, cwd = config["argv"], config["env"], config["cwd"]
    if config["op"] != "start" or not argv or not os.path.isabs(argv[0]) or not os.path.isabs(cwd):
        raise ValueError("absolute executable and cwd required")
    if not all(isinstance(x, str) for x in argv) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        raise ValueError("string argv/environment required")
    pid, master = pty.fork()
    if pid == 0:
        try:
            dimensions(0, config.get("rows", 32), config.get("cols", 120))
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        except BaseException:
            os._exit(127)
    incoming = bytearray(rest)
    output = bytearray()
    pending = bytearray()
    status = None
    stopping = None
    master_open = True
    stdin_open = True
    deadline = time.monotonic() + 180

    def kill(sig):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            pass

    def emit(record):
        output.extend(json.dumps(record).encode() + b"\n")
        if len(output) > LIMIT:
            raise BufferError("orchestrator output backlog")

    def stop():
        nonlocal stopping, stdin_open
        if stopping is None:
            stopping = time.monotonic()
            stdin_open = False
            kill(signal.SIGTERM)

    try:
        os.set_blocking(master, False)
        os.set_blocking(1, False)
        emit({"type": "started", "pid": pid})
        while True:
            now = time.monotonic()
            if now >= deadline:
                stop()
            if stopping is not None and now - stopping >= 2:
                kill(signal.SIGKILL)
            if stopping is not None and now - stopping >= 5:
                raise TimeoutError("PTY cleanup deadline")
            if status is None:
                found, result = os.waitpid(pid, os.WNOHANG)
                if found:
                    status = result
                    kill(signal.SIGKILL)  # Also fence remaining members of our group.
                    emit({"type": "exit", "code": os.waitstatus_to_exitcode(status)})
            if status is not None and not output:
                break
            reads = ([0] if stdin_open else []) + ([master] if master_open else [])
            writes = ([1] if output else []) + ([master] if pending and master_open else [])
            readable, writable, _ = select.select(reads, writes, [], 0.05)
            if 1 in writable:
                del output[:os.write(1, output)]
            if master in writable:
                del pending[:os.write(master, pending)]
            if master in readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if chunk:
                    emit({"type": "output", "data": base64.b64encode(chunk).decode("ascii")})
                else:
                    master_open = False
            if 0 in readable:
                chunk = os.read(0, 65536)
                if not chunk:
                    stop()
                incoming.extend(chunk)
            if len(incoming) > LIMIT:
                raise ValueError("protocol record too large")
            while b"\n" in incoming:
                line, _, rest = incoming.partition(b"\n")
                incoming = bytearray(rest)
                command = json.loads(line)
                if command["op"] == "input":
                    pending.extend(base64.b64decode(command["data"], validate=True))
                    if len(pending) > LIMIT:
                        raise BufferError("PTY input backlog")
                elif command["op"] == "resize":
                    dimensions(master, command["rows"], command["cols"])
                elif command["op"] == "terminate":
                    stop()
                else:
                    raise ValueError("unknown operation")
    finally:
        kill(signal.SIGKILL)
        os.close(master)
        if status is None:
            end = time.monotonic() + 3
            while time.monotonic() < end:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    break
                time.sleep(0.01)
            else:
                raise TimeoutError("could not reap PTY child")


if __name__ == "__main__":
    main()
