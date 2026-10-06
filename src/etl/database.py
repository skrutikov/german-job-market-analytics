"""Shared access to the job database."""

from collections.abc import Generator
from contextlib import contextmanager
from sqlalchemy import create_engine
from sqlalchemy.engine import Connection as SQLAlchemyConnection
from sqlalchemy.exc import SQLAlchemyError

from src.config.settings import DATABASE_URL
from src.monitoring.metrics import monitor_database_connection


class DatabaseUnavailableError(Exception):
    """Raised when the job database cannot be accessed."""


engine = create_engine(DATABASE_URL)


@monitor_database_connection
@contextmanager
def get_database_connection() -> Generator[SQLAlchemyConnection, None, None]:
    """Provide a configured connection to the job database."""
    try:
        with engine.connect() as connection:
            yield connection
    except SQLAlchemyError as error:
        raise DatabaseUnavailableError("Could not access the job database.") from error
