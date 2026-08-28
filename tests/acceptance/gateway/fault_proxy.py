#!/usr/bin/env python3
"""Restricted CONNECT proxy for VM-004/006 acceptance faults.

The proxy never performs TLS interception and never logs request headers or
payload bytes. It accepts only CONNECT from one configured lab client.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import ipaddress
import json
import select
import socket
import sys
import threading
from typing import IO, Optional, Tuple


MAX_HEADER = 16 * 1024


def parse_connect_line(line: bytes) -> Tuple[str, int]:
    try:
        method, authority, version = line.decode("ascii").strip().split(" ")
        host, port_text = authority.rsplit(":", 1)
        port = int(port_text)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("invalid CONNECT request line") from exc
    if method != "CONNECT" or version not in {"HTTP/1.0", "HTTP/1.1"}:
        raise ValueError("only CONNECT is supported")
    if not host or any(character in host for character in "/?#@") or port != 443:
        raise ValueError("only credential-free HTTPS authority targets are supported")
    return host.lower().rstrip("."), port


class EventLogger:
    def __init__(self, stream: IO[str]) -> None:
        self._stream = stream
        self._lock = threading.Lock()

    def write(self, client: str, host: Optional[str], port: Optional[int], event: str, byte_count: int) -> None:
        record = {
            "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "client": client,
            "targetHost": host,
            "targetPort": port,
            "event": event,
            "bytes": byte_count,
        }
        with self._lock:
            self._stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
            self._stream.flush()


@dataclasses.dataclass(frozen=True)
class Policy:
    allowed_client: ipaddress.IPv4Address
    mode: str
    probe_host: Optional[str]
    drop_after_bytes: int
    connect_timeout: float

    def action_for(self, host: str) -> str:
        if self.mode == "reject-connect":
            return "reject"
        if self.probe_host and host == self.probe_host:
            return "relay"
        return "drop"


def read_header(connection: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(2048)
        if not chunk:
            raise ValueError("connection closed before header")
        data.extend(chunk)
        if len(data) > MAX_HEADER:
            raise ValueError("header exceeds limit")
    return bytes(data)


def relay(client: socket.socket, upstream: socket.socket, byte_limit: Optional[int]) -> int:
    transferred = 0
    sockets = [client, upstream]
    while True:
        readable, _, exceptional = select.select(sockets, [], sockets, 30)
        if exceptional or not readable:
            return transferred
        for source in readable:
            target = upstream if source is client else client
            data = source.recv(16 * 1024)
            if not data:
                return transferred
            target.sendall(data)
            transferred += len(data)
            if byte_limit is not None and transferred >= byte_limit:
                return transferred


def handle(connection: socket.socket, address: Tuple[str, int], policy: Policy, logger: EventLogger) -> None:
    client_ip = address[0]
    host: Optional[str] = None
    port: Optional[int] = None
    transferred = 0
    try:
        if ipaddress.ip_address(client_ip) != policy.allowed_client:
            logger.write(client_ip, None, None, "client-rejected", 0)
            return
        header = read_header(connection)
        host, port = parse_connect_line(header.split(b"\r\n", 1)[0])
        action = policy.action_for(host)
        if action == "reject":
            connection.sendall(b"HTTP/1.1 502 Lab Fault\r\nConnection: close\r\n\r\n")
            logger.write(client_ip, host, port, "connect-rejected", 0)
            return
        upstream = socket.create_connection((host, port), timeout=policy.connect_timeout)
        try:
            connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            limit = None if action == "relay" else policy.drop_after_bytes
            transferred = relay(connection, upstream, limit)
            logger.write(client_ip, host, port, "relay-closed" if limit is None else "transfer-dropped", transferred)
        finally:
            upstream.close()
    except Exception as exc:  # event type only; exception text may contain input
        logger.write(client_ip, host, port, "proxy-error-" + type(exc).__name__, transferred)
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="192.168.77.1")
    parser.add_argument("--port", type=int, default=7897)
    parser.add_argument("--allowed-client", default="192.168.77.10")
    parser.add_argument("--mode", choices=("reject-connect", "probe-then-drop"), required=True)
    parser.add_argument("--probe-host", help="The one host relayed without a byte limit")
    parser.add_argument("--drop-after-bytes", type=int, default=65536)
    parser.add_argument("--connect-timeout", type=float, default=10.0)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    if args.mode == "probe-then-drop" and not args.probe_host:
        parser.error("--probe-host is required for probe-then-drop")
    if args.drop_after_bytes < 1 or not 1 <= args.port <= 65535:
        parser.error("port and byte limit must be positive")
    policy = Policy(
        allowed_client=ipaddress.ip_address(args.allowed_client),
        mode=args.mode,
        probe_host=args.probe_host.lower().rstrip(".") if args.probe_host else None,
        drop_after_bytes=args.drop_after_bytes,
        connect_timeout=args.connect_timeout,
    )
    with open(args.log, "x", encoding="utf-8") as log_stream:
        logger = EventLogger(log_stream)
        with socket.create_server((args.bind, args.port), reuse_port=False) as server:
            while True:
                connection, address = server.accept()
                threading.Thread(target=handle, args=(connection, address, policy, logger), daemon=True).start()
    return 0


if __name__ == "__main__":
    sys.exit(main())
