"""Tests for parse_jacoco.py — JaCoCo XML coverage report parser."""

import os
import tempfile

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
