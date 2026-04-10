"""Shared test fixtures for sdlc gates script tests.

The sys.path insert at module top lets test files import sibling
utility modules (is_allowed_check, report_unused_entries, etc.) with
plain top-level imports. find_affected_tests.py reads imports via AST,
so this makes the source→test dependency visible to the import graph.
"""

import json
import os
import shutil
import sys
import tempfile

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _make_proof_dir(proofs):
    """Standalone helper: create a temp dir with proof JSON files.

    Use this in non-fixture contexts (e.g. CLI subprocess tests).
    Caller is responsible for cleanup.
    """
    d = tempfile.mkdtemp()
    for name, data in proofs.items():
        with open(os.path.join(d, f"{name}.json"), "w") as f:
            json.dump(data, f)
    return d


@pytest.fixture
def make_proof_dir():
    """Factory fixture: create a temp dir with proof JSON files."""
    dirs = []

    def _factory(proofs):
        d = _make_proof_dir(proofs)
        dirs.append(d)
        return d

    yield _factory

    for d in dirs:
        shutil.rmtree(d, ignore_errors=True)
