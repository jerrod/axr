"""Tests for parse_cobertura.py — Cobertura XML coverage report parser."""

import os
import tempfile

from parse_cobertura import parse_cobertura


SAMPLE_COBERTURA = """\
<?xml version="1.0" ?>
<coverage version="1" timestamp="1234567890" lines-valid="100" lines-covered="85"
         line-rate="0.85" branches-valid="20" branches-covered="16" branch-rate="0.8"
         complexity="0">
  <packages>
    <package name="com.example" line-rate="0.85">
      <classes>
        <class name="Foo" filename="src/main/kotlin/com/example/Foo.kt" line-rate="0.90">
          <lines>
            <line number="1" hits="1"/>
          </lines>
        </class>
        <class name="Bar" filename="src/main/kotlin/com/example/Bar.kt" line-rate="0.75">
          <lines>
            <line number="1" hits="1"/>
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
"""


def _write_xml(content):
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".xml", delete=False)
    f.write(content)
    f.flush()
    f.close()
    return f.name


def test_parse_cobertura_basic():
    path = _write_xml(SAMPLE_COBERTURA)
    try:
        result = parse_cobertura(path)
        foo = result["src/main/kotlin/com/example/Foo.kt"]
        assert foo["lines"]["pct"] == 90.0
        bar = result["src/main/kotlin/com/example/Bar.kt"]
        assert bar["lines"]["pct"] == 75.0
    finally:
        os.unlink(path)


def test_parse_cobertura_no_files():
    result = parse_cobertura("/nonexistent/*.xml")
    assert result == {}


def test_parse_cobertura_zero_coverage():
    xml = """\
<?xml version="1.0" ?>
<coverage line-rate="0">
  <packages><package name="com.example" line-rate="0">
    <classes>
      <class name="Empty" filename="src/Empty.kt" line-rate="0.0">
        <lines><line number="1" hits="0"/></lines>
      </class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(xml)
    try:
        result = parse_cobertura(path)
        assert result["src/Empty.kt"]["lines"]["pct"] == 0.0
    finally:
        os.unlink(path)


def test_parse_cobertura_glob_multiple():
    dir = tempfile.mkdtemp()
    xml1 = '<?xml version="1.0" ?><coverage><packages><package name="a"><classes><class name="A" filename="A.kt" line-rate="0.9"><lines/></class></classes></package></packages></coverage>'
    xml2 = '<?xml version="1.0" ?><coverage><packages><package name="b"><classes><class name="B" filename="B.kt" line-rate="0.5"><lines/></class></classes></package></packages></coverage>'
    p1, p2 = os.path.join(dir, "a.xml"), os.path.join(dir, "b.xml")
    with open(p1, "w") as f:
        f.write(xml1)
    with open(p2, "w") as f:
        f.write(xml2)
    try:
        result = parse_cobertura(os.path.join(dir, "*.xml"))
        assert result["A.kt"]["lines"]["pct"] == 90.0
        assert result["B.kt"]["lines"]["pct"] == 50.0
    finally:
        os.unlink(p1)
        os.unlink(p2)
        os.rmdir(dir)
