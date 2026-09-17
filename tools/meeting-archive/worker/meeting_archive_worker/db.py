"""Small SQLite lifecycle helpers shared by the worker stores."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from contextlib import contextmanager


@contextmanager
def closing_connection(
    factory: Callable[[], sqlite3.Connection],
) -> Iterator[sqlite3.Connection]:
    """Commit or roll back like sqlite's context manager, then always close."""

    connection = factory()
    try:
        with connection:
            yield connection
    finally:
        connection.close()
