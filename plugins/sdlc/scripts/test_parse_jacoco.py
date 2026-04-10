"""Tests for parse_jacoco.py — JaCoCo XML coverage report parser."""

import json
import os
import tempfile

import pytest

import parse_jacoco as parse_jacoco_mod
from parse_jacoco import parse_jacoco


SAMPLE_JACOCO = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="core-api">
  <package name="co/arqu/core/service">
    <sourcefile name="FooService.kt">
      <counter type="LINE" missed="5" covered="20"/>
      <counter type="BRANCH" missed="2" covered="8"/>
    </sourcefile>
    <sourcefile name="BarService.kt">
      <counter type="LINE" missed="0" covered="30"/>
    </sourcefile>
  </package>
  <package name="co/arqu/core/model">
    <sourcefile name="User.kt">
      <counter type="LINE" missed="10" covered="10"/>
    </sourcefile>
  </package>
</report>
"""


def _write_xml(content, dir=None):
    f = tempfile.NamedTemporaryFile(
        mode="w", suffix=".xml", delete=False, dir=dir
    )
    f.write(content)
    f.flush()
    f.close()
    return f.name


def test_parse_basic_coverage():
    path = _write_xml(SAMPLE_JACOCO)
    try:
        result = parse_jacoco(path)
        foo = result["co/arqu/core/service/FooService.kt"]
        assert foo["lines"]["pct"] == 80.0  # 20/(20+5)*100
        bar = result["co/arqu/core/service/BarService.kt"]
        assert bar["lines"]["pct"] == 100.0
        user = result["co/arqu/core/model/User.kt"]
        assert user["lines"]["pct"] == 50.0
    finally:
        os.unlink(path)


def test_parse_glob_multiple_reports():
    dir = tempfile.mkdtemp()
    report1 = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="module-a">
  <package name="com/example/a">
    <sourcefile name="A.kt">
      <counter type="LINE" missed="1" covered="9"/>
    </sourcefile>
  </package>
</report>
"""
    report2 = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="module-b">
  <package name="com/example/b">
    <sourcefile name="B.kt">
      <counter type="LINE" missed="5" covered="5"/>
    </sourcefile>
  </package>
</report>
"""
    path1 = os.path.join(dir, "report1.xml")
    path2 = os.path.join(dir, "report2.xml")
    with open(path1, "w") as f:
        f.write(report1)
    with open(path2, "w") as f:
        f.write(report2)
    try:
        result = parse_jacoco(os.path.join(dir, "*.xml"))
        assert result["com/example/a/A.kt"]["lines"]["pct"] == 90.0
        assert result["com/example/b/B.kt"]["lines"]["pct"] == 50.0
    finally:
        os.unlink(path1)
        os.unlink(path2)
        os.rmdir(dir)


def test_parse_zero_lines():
    xml = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="empty">
  <package name="com/example">
    <sourcefile name="Empty.kt">
      <counter type="LINE" missed="0" covered="0"/>
    </sourcefile>
  </package>
</report>
"""
    path = _write_xml(xml)
    try:
        result = parse_jacoco(path)
        assert result["com/example/Empty.kt"]["lines"]["pct"] == 0
    finally:
        os.unlink(path)


def test_parse_no_matching_files():
    result = parse_jacoco("/nonexistent/path/*.xml")
    assert result == {}


def test_parse_sourcefile_without_line_counter_is_skipped():
    # A sourcefile that only has BRANCH/METHOD counters (no LINE) must be
    # skipped entirely — _extract_line_pct returns None.
    xml = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="no-line">
  <package name="com/example">
    <sourcefile name="NoLine.kt">
      <counter type="BRANCH" missed="1" covered="2"/>
      <counter type="METHOD" missed="0" covered="3"/>
    </sourcefile>
    <sourcefile name="HasLine.kt">
      <counter type="LINE" missed="0" covered="10"/>
    </sourcefile>
  </package>
</report>
"""
    path = _write_xml(xml)
    try:
        result = parse_jacoco(path)
        assert "com/example/NoLine.kt" not in result
        assert result["com/example/HasLine.kt"]["lines"]["pct"] == 100.0
    finally:
        os.unlink(path)


def test_parse_rejects_xml_with_entity_declarations():
    # Billion-laughs / XXE guard: presence of "<!ENTITY" must raise.
    xml = """\
<?xml version="1.0"?>
<!DOCTYPE report [
  <!ENTITY lol "lol">
]>
<report name="evil">
  <package name="com/example">
    <sourcefile name="Evil.kt">
      <counter type="LINE" missed="0" covered="1"/>
    </sourcefile>
  </package>
</report>
"""
    path = _write_xml(xml)
    try:
        with pytest.raises(ValueError, match="entity declarations"):
            parse_jacoco(path)
    finally:
        os.unlink(path)


def test_parse_sourcefile_without_package_name_uses_bare_filename():
    # When package name is empty, the file key should be just the sourcefile name
    # (not prefixed with "/"). Exercises the `file_key = fname` branch.
    xml = """\
<?xml version="1.0" encoding="UTF-8"?>
<report name="rootless">
  <package name="">
    <sourcefile name="Root.kt">
      <counter type="LINE" missed="0" covered="4"/>
    </sourcefile>
  </package>
</report>
"""
    path = _write_xml(xml)
    try:
        result = parse_jacoco(path)
        assert result["Root.kt"]["lines"]["pct"] == 100.0
    finally:
        os.unlink(path)


# --- __main__ entrypoint ---
_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(parse_jacoco_mod.__file__)),
    "parse_jacoco.py",
)


def test_main_no_args_exits_with_usage_error(monkeypatch, capsys):
    import runpy

    monkeypatch.setattr("sys.argv", ["parse_jacoco.py"])
    with pytest.raises(SystemExit) as exc:
        runpy.run_path(_MODULE_PATH, run_name="__main__")
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "Usage" in err


def test_main_with_arg_prints_parsed_json(monkeypatch, capsys):
    import runpy

    path = _write_xml(SAMPLE_JACOCO)
    try:
        monkeypatch.setattr("sys.argv", ["parse_jacoco.py", path])
        runpy.run_path(_MODULE_PATH, run_name="__main__")
        out = capsys.readouterr().out.strip()
        parsed = json.loads(out)
        assert parsed["co/arqu/core/service/FooService.kt"] == {
            "lines": {"pct": 80.0}
        }
        assert parsed["co/arqu/core/service/BarService.kt"] == {
            "lines": {"pct": 100.0}
        }
        assert parsed["co/arqu/core/model/User.kt"] == {"lines": {"pct": 50.0}}
    finally:
        os.unlink(path)
