#!/usr/bin/env python3
# AquaVR Фаза 2: замер скорости тракта ПК -> (usbmuxd/Lightning USB) -> iPhone.
# Работает через туннель, поднятый scripts/phase2_usb.ps1:
#   ПК:9943 -> iPhone app 9943 (управление, текстовые строки \n)
#   ПК:9944 -> iPhone app 9944 (данные, сырой TCP)
#
# Использование: py tools/aqua_speedtest.py [МБ_на_тест]  (по умолчанию 33 МБ)

import select
import socket
import sys
import time

HOST = "127.0.0.1"
CONTROL_PORT = 9943
DATA_PORT = 9944
CHUNK = 256 * 1024
ZERO = bytes(CHUNK)


class ControlError(Exception):
    pass


class LineSock:
    """Читает \\n-терминированные строки из неблокирующего сокета."""

    def __init__(self, sock):
        self.s = sock
        self.buf = b""
        self.lines = []

    def pump(self, timeout=0):
        if not self.lines:
            r, _, _ = select.select([self.s], [], [], timeout)
            if r:
                d = self.s.recv(65536)
                if not d:
                    raise ControlError("управляющий канал закрылся")
                self.buf += d
                while b"\n" in self.buf:
                    line, self.buf = self.buf.split(b"\n", 1)
                    self.lines.append(line.decode(errors="replace").strip())
        return self.lines.pop(0) if self.lines else None

    def wait_line(self, timeout=5):
        deadline = time.perf_counter() + timeout
        while True:
            line = self.pump(0.5)
            if line:
                return line
            if time.perf_counter() > deadline:
                raise ControlError("таймаут ответа от телефона")


def connect(port, timeout=5):
    try:
        return socket.create_connection((HOST, port), timeout)
    except OSError as e:
        print(f"ERR: не подключиться к {HOST}:{port}: {e}")
        print("Подсказки: 1) на iPhone запущено AquaVR и нажат 'Старт USB 9943/9944'?")
        print("           2) туннель поднят? (scripts/phase2_usb.bat)")
        sys.exit(1)


def parse_done(line, kind):
    # формат: "DONE RX <байт> <мс>"
    parts = line.split()
    return {"bytes": int(parts[2]), "ms": max(int(parts[3]), 1)}


def mbps(b, ms):
    return b * 8 / ms / 1000


def main():
    mb = int(sys.argv[1]) if len(sys.argv) > 1 else 33
    total = mb * 1024 * 1024

    ctl_sock = connect(CONTROL_PORT)
    ctl_sock.setblocking(False)
    ctl = LineSock(ctl_sock)

    hello = ctl.wait_line()
    print(f"телефон: {hello}")
    ctl_sock.sendall(b"HELLO\n")
    resp = ctl.wait_line()
    if resp != "OK AquaUSB 0.1":
        print(f"ERR: неожиданный ответ на HELLO: {resp}")
        sys.exit(1)
    print("протокол согласован, тест RX/ TX по", mb, "МБ")

    print("\n[RX: ПК -> iPhone]", flush=True)
    data = connect(DATA_PORT)
    ctl_sock.sendall(f"RX {total}\n".encode())
    ready = ctl.wait_line()
    if not ready.startswith("READY RX"):
        print(f"ERR: ждал READY RX, получил: {ready}")
        sys.exit(1)
    sent = 0
    t0 = time.perf_counter()
    done = None
    while sent < total:
        line = ctl.pump(0)
        if line and line.startswith("DONE RX"):
            done = parse_done(line, "RX")
            break
        n = min(CHUNK, total - sent)
        data.sendall(ZERO[:n])
        sent += n
    if done is None:
        line = ctl.wait_line(15)
        if not line.startswith("DONE RX"):
            print(f"ERR: ждал DONE RX, получил: {line}")
            sys.exit(1)
        done = parse_done(line, "RX")
    pc_ms = max(int((time.perf_counter() - t0) * 1000), 1)
    data.close()
    print(f"  телефон принял {done['bytes']} байт за {done['ms']} мс "
          f"= {mbps(done['bytes'], done['ms']):.1f} Мбит/с (по часам телефона)")
    print(f"  ПК отправил {done['bytes']} байт за {pc_ms} мс = {mbps(done['bytes'], pc_ms):.1f} Мбит/с (по часам ПК)")

    print("\n[TX: iPhone -> ПК]", flush=True)
    data = connect(DATA_PORT)
    ctl_sock.sendall(f"TX {total}\n".encode())
    ready = ctl.wait_line()
    if not ready.startswith("READY TX"):
        print(f"ERR: ждал READY TX, получил: {ready}")
        sys.exit(1)
    got = 0
    t0 = time.perf_counter()
    while got < total:
        chunk = data.recv(65536)
        if not chunk:
            print("ERR: канал данных закрылся раньше времени")
            sys.exit(1)
        got += len(chunk)
    pc_ms = max(int((time.perf_counter() - t0) * 1000), 1)
    line = ctl.wait_line(15)
    if not line.startswith("DONE TX"):
        print(f"ERR: ждал DONE TX, получил: {line}")
        sys.exit(1)
    done = parse_done(line, "TX")
    data.close()
    print(f"  телефон отдал {done['bytes']} байт за {done['ms']} мс "
          f"= {mbps(done['bytes'], done['ms']):.1f} Мбит/с (по часам телефона)")
    print(f"  ПК принял {got} байт за {pc_ms} мс = {mbps(got, pc_ms):.1f} Мбит/с (по часам ПК)")

    print("\n== Итог ==")
    print("Lightning = USB 2.0, ориентир: 150-250 Мбит/с в обе стороны.")
    print("Пришли обе цифры (RX и TX) мне в чат.")


if __name__ == "__main__":
    main()
