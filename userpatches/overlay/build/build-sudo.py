#!/usr/bin/python3 -I
"""sudo for the image chroot: under qemu-user the setuid bit is ignored, so the client sends
argv, env, cwd and stdin to a root server (--serve SOCKET) that runs it and returns the output."""
import json
import os
import pwd
import select
import socket
import struct
import subprocess
import sys
import threading

SOCKET = "/tmp/libreq1pro-sudo.sock"
SECURE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
KEEP_ENV = ("TERM", "LANG", "LC_ALL", "DEBIAN_FRONTEND", "COLUMNS", "LINES")


def send(sock, kind, data=b""):
    sock.sendall(kind + struct.pack(">I", len(data)) + data)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def recv(sock):
    head = recv_exact(sock, 5)
    return head[:1], recv_exact(sock, struct.unpack(">I", head[1:])[0])


# ---- server -----------------------------------------------------------------

def handle(conn):
    with conn:
        _, header = recv(conn)
        req = json.loads(header)
        argv = req["argv"]
        if req["user"] not in ("root", "0"):
            argv = ["runuser", "-u", req["user"], "--"] + argv
        try:
            proc = subprocess.Popen(argv, cwd=req["cwd"], env=req["env"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
        except OSError as e:
            send(conn, b"E", f"sudo: {argv[0]}: {e.strerror}\n".encode())
            send(conn, b"X", struct.pack(">i", 127))
            return
        lock = threading.Lock()

        def pump_out(stream, kind):
            for chunk in iter(lambda: stream.read1(65536), b""):
                with lock:
                    send(conn, kind, chunk)

        def pump_in():
            try:
                while True:
                    kind, data = recv(conn)
                    if kind != b"I" or not data:
                        break
                    proc.stdin.write(data)
                    proc.stdin.flush()
            except (EOFError, OSError):
                pass
            try:
                proc.stdin.close()
            except OSError:
                pass

        outs = [threading.Thread(target=pump_out, args=(proc.stdout, b"O")),
                threading.Thread(target=pump_out, args=(proc.stderr, b"E"))]
        threading.Thread(target=pump_in, daemon=True).start()
        for t in outs:
            t.start()
        for t in outs:
            t.join()
        rc = proc.wait()
        with lock:
            send(conn, b"X", struct.pack(">i", rc if rc >= 0 else 128 - rc))


def serve(path):
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o666)
    srv.listen(16)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


# ---- client -----------------------------------------------------------------

def usage():
    sys.stderr.write("usage: sudo [-u user] [-EHnS] [VAR=value...] command\n")
    sys.exit(1)


def parse(args):
    user, keep_env, i = "root", False, 0
    while i < len(args) and args[i].startswith("-"):
        a = args[i]
        i += 1
        if a == "--":
            break
        if a.startswith("--preserve-env"):
            keep_env = True
            continue
        if a.startswith("--user="):
            user = a.split("=", 1)[1]
            continue
        if a in ("--user", "--group"):
            if i >= len(args):
                usage()
            if a == "--user":
                user = args[i]
            i += 1
            continue
        flags = a[1:]
        while flags:
            f, flags = flags[0], flags[1:]
            if f in "ug":
                value = flags or (args[i] if i < len(args) else usage())
                if not flags:
                    i += 1
                flags = ""
                if f == "u":
                    user = value
            elif f == "E":
                keep_env = True
            elif f in "kKv":
                if i >= len(args):
                    sys.exit(0)
            elif f not in "HnSAPb":
                sys.stderr.write(f"sudo: option -{f} not supported at build time\n")
                sys.exit(1)
    assign = {}
    while i < len(args) and "=" in args[i] and not args[i].startswith("="):
        k, v = args[i].split("=", 1)
        assign[k] = v
        i += 1
    if i >= len(args):
        usage()
    return user, keep_env, assign, args[i:]


def client(args):
    user, keep_env, assign, argv = parse(args)
    caller = pwd.getpwuid(os.getuid())
    target = pwd.getpwnam(user) if not user.isdigit() else pwd.getpwuid(int(user))
    if keep_env:
        env = dict(os.environ)
    else:
        env = {k: os.environ[k] for k in KEEP_ENV if k in os.environ}
    env.update(HOME=target.pw_dir, USER=target.pw_name, LOGNAME=target.pw_name,
               SHELL=target.pw_shell, PATH=SECURE_PATH,
               SUDO_USER=caller.pw_name, SUDO_UID=str(caller.pw_uid),
               SUDO_GID=str(caller.pw_gid), SUDO_COMMAND=" ".join(argv))
    env.update(assign)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET)
    send(sock, b"H", json.dumps({"argv": argv, "user": target.pw_name,
                                 "env": env, "cwd": os.getcwd()}).encode())
    stdin = sys.stdin.buffer
    watch = [sock, stdin]
    while True:
        ready, _, _ = select.select(watch, [], [])
        if stdin in ready:
            data = os.read(stdin.fileno(), 65536)
            send(sock, b"I", data)
            if not data:
                watch.remove(stdin)
        if sock in ready:
            kind, data = recv(sock)
            if kind == b"O":
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            elif kind == b"E":
                sys.stderr.buffer.write(data)
                sys.stderr.buffer.flush()
            elif kind == b"X":
                sys.exit(struct.unpack(">i", data)[0])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--serve"]:
        serve(sys.argv[2] if len(sys.argv) > 2 else SOCKET)
    else:
        client(sys.argv[1:])
