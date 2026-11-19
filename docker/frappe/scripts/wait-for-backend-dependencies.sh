#!/bin/bash

wait_for_backend_dependencies() (
  set -euo pipefail

  db_host="${DB_HOST:-mariadb-db}"
  redis_cache_host="${REDIS_CACHE_HOST:-redis-cache}"
  redis_queue_host="${REDIS_QUEUE_HOST:-redis-queue}"
  db_port="${DB_PORT:-3306}"
  redis_cache_port="${REDIS_CACHE_PORT:-6379}"
  redis_queue_port="${REDIS_QUEUE_PORT:-6379}"

  dependency_is_ready() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import socket
import sys

dependency, name, host, port = sys.argv[1:]


def receive_exact(connection, length):
    data = bytearray()
    while len(data) < length:
        chunk = connection.recv(length - len(data))
        if not chunk:
            raise EOFError("connection closed before protocol response")
        data.extend(chunk)
    return bytes(data)


def mariadb_ready(host, port):
    with socket.create_connection((host, port), timeout=1) as connection:
        connection.settimeout(1)
        header = receive_exact(connection, 4)
        payload_length = int.from_bytes(header[:3], "little")
        if payload_length < 1 or payload_length > 65536:
            raise RuntimeError(f"invalid greeting packet length {payload_length}")
        greeting = receive_exact(connection, payload_length)
        if greeting[0] != 10:
            raise RuntimeError(f"unexpected protocol version {greeting[0]}")
        return True


def redis_ready(host, port):
    with socket.create_connection((host, port), timeout=1) as connection:
        connection.settimeout(1)
        connection.sendall(b"*1\r\n$4\r\nPING\r\n")
        response = b""
        while not response.endswith(b"\r\n") and len(response) < 128:
            chunk = connection.recv(128 - len(response))
            if not chunk:
                break
            response += chunk
        if response != b"+PONG\r\n":
            raise RuntimeError(f"unexpected PING response: {response!r}")
        return True


try:
    if dependency == "mariadb":
        ready = mariadb_ready(host, int(port))
    else:
        ready = redis_ready(host, int(port))
except (OSError, EOFError, ValueError, RuntimeError) as error:
    print(
        f"{name} check failed for {host}:{port}: "
        f"{type(error).__name__}: {error}",
        file=sys.stderr,
        flush=True,
    )
    ready = False

if not ready:
    sys.exit(1)
PY
  }

  wait_for_dependency() {
    local name="$1"
    local dependency="$2"
    local host="$3"
    local port="$4"
    local scheme="$5"
    local seconds=0

    echo "Checking ${name} connection: ${scheme}://${host}:${port} (host=${host}, port=${port})"
    while ! dependency_is_ready "${dependency}" "${name}" "${host}" "${port}"; do
      sleep 1
      seconds=$((seconds + 1))
      echo "Still waiting for ${name} at ${host}:${port} (${seconds}s)"
    done
    echo "${name} is ready"
  }

  wait_for_dependency "MariaDB" "mariadb" "${db_host}" "${db_port}" "mysql"
  echo "MariaDB connection successful; moving to Redis cache stage"
  wait_for_dependency "Redis cache" "redis" "${redis_cache_host}" "${redis_cache_port}" "redis"
  echo "Redis cache connection successful; moving to Redis queue stage"
  wait_for_dependency "Redis queue" "redis" "${redis_queue_host}" "${redis_queue_port}" "redis"
  echo "Redis queue connection successful; all dependencies are ready"
)

wait_for_backend_dependencies
