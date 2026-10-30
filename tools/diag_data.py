import socket
import time

HOST = "127.0.0.1"


def connect(port, timeout=5):
    return socket.create_connection((HOST, port), timeout)


def read_line(s, timeout=5):
    s.settimeout(timeout)
    b = b""
    while not b.endswith(b"\n"):
        d = s.recv(1)
        if not d:
            raise RuntimeError("ctl closed")
        b += d
    return b.decode().strip()


c = connect(9943)
print("ctl greeting:", read_line(c))
c.sendall(b"HELLO\n")
print("ctl hello:", read_line(c))

d = connect(9944)
d.settimeout(10)
payload = b"\x00" * (1024 * 1024)
t0 = time.perf_counter()
try:
    d.sendall(payload)
    dt = time.perf_counter() - t0
    print(f"data sendall 1MB OK in {dt*1000:.0f} ms ({8 / dt / 1000:.1f} Mbit/s)")
except Exception as e:
    print("data sendall FAIL:", type(e).__name__, e)

time.sleep(0.5)
c.sendall(b"STAT\n")
try:
    while True:
        line = read_line(c, timeout=3)
        print("ctl:", line)
        if line.startswith("STAT"):
            break
except Exception as e:
    print("ctl read fail:", type(e).__name__, e)

d.close()
c.close()
print("diag done")
