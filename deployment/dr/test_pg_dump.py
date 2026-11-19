"""Test the offline PostgreSQL header/stream checker."""

import io
import unittest

from deployment.dr.check_pg_dump import consume_pg_dump


class PgDumpTests(unittest.TestCase):
    def test_valid_stream(self):
        self.assertEqual(consume_pg_dump(io.BytesIO(b"PGDMP" + b"0" * 95)), 100)

    def test_wrong_header(self):
        with self.assertRaisesRegex(ValueError, "PGDMP"):
            consume_pg_dump(io.BytesIO(b"wrong" + b"0" * 95))

    def test_truncated(self):
        with self.assertRaisesRegex(ValueError, "too short"):
            consume_pg_dump(io.BytesIO(b"PGDMP"))


if __name__ == "__main__":
    unittest.main()
