"""Tests for shared fixtures in conftest.py.

These exist so the conftest module itself (_make_proof_dir helper and
the make_proof_dir factory fixture) is covered by the coverage gate
when tests for other modules in this branch don't happen to use them.
"""

import json
import os
import shutil

import conftest


def test_make_proof_dir_helper_writes_json_files():
    proofs = {
        "lint": {"gate": "lint", "status": "pass"},
        "tests": {"gate": "tests", "status": "pass", "tests_ran": True},
    }
    d = conftest._make_proof_dir(proofs)
    try:
        assert os.path.isdir(d)
        for name, expected in proofs.items():
            path = os.path.join(d, f"{name}.json")
            assert os.path.isfile(path)
            with open(path) as f:
                assert json.load(f) == expected
    finally:
        # _make_proof_dir caller is responsible for cleanup
        shutil.rmtree(d, ignore_errors=True)


def test_make_proof_dir_helper_empty_proofs():
    d = conftest._make_proof_dir({})
    try:
        assert os.path.isdir(d)
        assert os.listdir(d) == []
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_make_proof_dir_fixture_creates_and_cleans_up(make_proof_dir):
    d = make_proof_dir({"gate1": {"status": "pass"}})
    assert os.path.isdir(d)
    assert os.path.isfile(os.path.join(d, "gate1.json"))
    with open(os.path.join(d, "gate1.json")) as f:
        assert json.load(f) == {"status": "pass"}
    # Teardown happens in conftest's make_proof_dir fixture after yield —
    # the next test records the dirs so pytest's finalizer path is exercised.


def test_make_proof_dir_fixture_tracks_multiple_dirs(make_proof_dir):
    # The factory fixture tracks every dir it creates so teardown can
    # remove all of them. Exercise the list-of-dirs code path.
    d1 = make_proof_dir({"a": {}})
    d2 = make_proof_dir({"b": {}})
    assert d1 != d2
    assert os.path.isdir(d1)
    assert os.path.isdir(d2)
