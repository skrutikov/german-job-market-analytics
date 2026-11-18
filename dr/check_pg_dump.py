#!/usr/bin/env python3
"""Consume a complete PostgreSQL custom-format dump stream.

This checks the PGDMP signature and reads all decrypted bytes, allowing
age to authenticate the full stream. It does NOT validate pg_restore's TOC
or prove that the dump is restorable.
"""
import sys


def consume_pg_dump(stream):
    header = stream.read(5)
    if header != b"PGDMP":
        raise ValueError("Not a PostgreSQL custom-format dump (PGDMP header missing)")
    size = len(header)
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        size += len(chunk)
    if size < 64:
        raise ValueError("PostgreSQL dump is too short")
    return size


def main():
    try:
        size = consume_pg_dump(sys.stdin.buffer)
    except ValueError as exc:
        print(f"PostgreSQL dump check failed: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"PGDMP signature and complete decrypted stream: OK ({size} bytes)")


if __name__ == "__main__":
    main()
