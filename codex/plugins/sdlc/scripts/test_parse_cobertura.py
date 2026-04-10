"""Tests for parse_cobertura.py — Cobertura XML coverage report parser."""

import json
import os

import pytest

import parse_cobertura
from parse_cobertura import _safe_parse, parse_cobertura as parse


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


def _write_xml(tmp_path, content, name="coverage.xml"):
    path = tmp_path / name
    path.write_text(content)
    return str(path)


# --- parse_cobertura — happy path ---
def test_parse_cobertura_basic(tmp_path):
    path = _write_xml(tmp_path, SAMPLE_COBERTURA)
    result = parse(path)
    assert result["src/main/kotlin/com/example/Foo.kt"]["lines"]["pct"] == 90.0
    assert result["src/main/kotlin/com/example/Bar.kt"]["lines"]["pct"] == 75.0


def test_parse_cobertura_no_matching_files():
    result = parse("/nonexistent/path/*.xml")
    assert result == {}


def test_parse_cobertura_zero_coverage(tmp_path):
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
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result["src/Empty.kt"]["lines"]["pct"] == 0.0


def test_parse_cobertura_full_coverage(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<coverage line-rate="1.0">
  <packages><package name="p" line-rate="1.0">
    <classes>
      <class name="Full" filename="Full.kt" line-rate="1.0">
        <lines><line number="1" hits="1"/></lines>
      </class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result["Full.kt"]["lines"]["pct"] == 100.0


def test_parse_cobertura_glob_multiple_files(tmp_path):
    xml1 = (
        '<?xml version="1.0" ?><coverage><packages><package name="a">'
        '<classes><class name="A" filename="A.kt" line-rate="0.9"><lines/>'
        "</class></classes></package></packages></coverage>"
    )
    xml2 = (
        '<?xml version="1.0" ?><coverage><packages><package name="b">'
        '<classes><class name="B" filename="B.kt" line-rate="0.5"><lines/>'
        "</class></classes></package></packages></coverage>"
    )
    _write_xml(tmp_path, xml1, "a.xml")
    _write_xml(tmp_path, xml2, "b.xml")
    result = parse(os.path.join(str(tmp_path), "*.xml"))
    assert result["A.kt"]["lines"]["pct"] == 90.0
    assert result["B.kt"]["lines"]["pct"] == 50.0


def test_parse_cobertura_empty_packages(tmp_path):
    xml = '<?xml version="1.0" ?><coverage line-rate="0"><packages/></coverage>'
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result == {}


def test_parse_cobertura_class_missing_filename_is_skipped(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<coverage>
  <packages><package name="p">
    <classes>
      <class name="NoFile" line-rate="0.5"><lines/></class>
      <class name="Good" filename="Good.kt" line-rate="0.8"><lines/></class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert "Good.kt" in result
    assert len(result) == 1


def test_parse_cobertura_class_missing_line_rate_is_skipped(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<coverage>
  <packages><package name="p">
    <classes>
      <class name="NoRate" filename="NoRate.kt"><lines/></class>
      <class name="Good" filename="Good.kt" line-rate="0.8"><lines/></class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert "NoRate.kt" not in result
    assert result["Good.kt"]["lines"]["pct"] == 80.0


def test_parse_cobertura_class_with_no_lines_element(tmp_path):
    # Some tools emit <class> without any <lines> child; should still parse.
    xml = """\
<?xml version="1.0" ?>
<coverage>
  <packages><package name="p">
    <classes>
      <class name="Lean" filename="Lean.kt" line-rate="0.6"/>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result["Lean.kt"]["lines"]["pct"] == 60.0


def test_parse_cobertura_multiple_classes_per_package(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<coverage>
  <packages><package name="p">
    <classes>
      <class name="A" filename="A.kt" line-rate="0.1"><lines/></class>
      <class name="B" filename="B.kt" line-rate="0.2"><lines/></class>
      <class name="C" filename="C.kt" line-rate="0.3"><lines/></class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result["A.kt"]["lines"]["pct"] == 10.0
    assert result["B.kt"]["lines"]["pct"] == 20.0
    assert result["C.kt"]["lines"]["pct"] == 30.0


def test_parse_cobertura_rounds_to_one_decimal(tmp_path):
    # 1/3 = 0.3333... → 33.3 after round(*100, 1)
    xml = """\
<?xml version="1.0" ?>
<coverage>
  <packages><package name="p">
    <classes>
      <class name="Third" filename="Third.kt" line-rate="0.3333333"><lines/></class>
    </classes>
  </package></packages>
</coverage>
"""
    path = _write_xml(tmp_path, xml)
    result = parse(path)
    assert result["Third.kt"]["lines"]["pct"] == 33.3


def test_parse_cobertura_malformed_xml_raises(tmp_path):
    from xml.etree.ElementTree import ParseError

    path = _write_xml(tmp_path, "<coverage><packages><not closed")
    with pytest.raises(ParseError):
        parse(path)


# --- _safe_parse — XXE/entity rejection ---
def test_safe_parse_rejects_entity_declaration(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<!DOCTYPE coverage [
  <!ENTITY lol "lol">
]>
<coverage><packages/></coverage>
"""
    path = _write_xml(tmp_path, xml, "evil.xml")
    with pytest.raises(ValueError, match="entity declarations"):
        _safe_parse(path)


def test_safe_parse_rejects_billion_laughs(tmp_path):
    # Nested entity expansion (billion-laughs) must also be rejected, not
    # just the trivial single <!ENTITY> case.
    xml = """\
<?xml version="1.0" ?>
<!DOCTYPE coverage [
  <!ENTITY lol "lol">
  <!ENTITY lol2 "&lol;&lol;&lol;&lol;">
  <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;">
]>
<coverage><packages/></coverage>
"""
    path = _write_xml(tmp_path, xml, "billion.xml")
    with pytest.raises(ValueError, match="entity declarations"):
        _safe_parse(path)


def test_parse_cobertura_rejects_entity_declaration_via_public_api(tmp_path):
    xml = """\
<?xml version="1.0" ?>
<!DOCTYPE coverage [<!ENTITY x "y">]>
<coverage><packages/></coverage>
"""
    path = _write_xml(tmp_path, xml, "evil.xml")
    with pytest.raises(ValueError, match="entity declarations"):
        parse(path)


# --- __main__ entrypoint — exercised via runpy so coverage sees the real block ---
_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(parse_cobertura.__file__)),
    "parse_cobertura.py",
)


def test_main_no_args_exits_with_usage_error(monkeypatch, capsys):
    import runpy

    monkeypatch.setattr("sys.argv", ["parse_cobertura.py"])
    with pytest.raises(SystemExit) as exc:
        runpy.run_path(_MODULE_PATH, run_name="__main__")
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "Usage" in err


def test_main_with_arg_prints_parsed_json(tmp_path, monkeypatch, capsys):
    import runpy

    path = _write_xml(tmp_path, SAMPLE_COBERTURA)
    monkeypatch.setattr("sys.argv", ["parse_cobertura.py", path])
    runpy.run_path(_MODULE_PATH, run_name="__main__")
    out = capsys.readouterr().out.strip()
    parsed = json.loads(out)
    assert parsed["src/main/kotlin/com/example/Foo.kt"]["lines"]["pct"] == 90.0
    assert parsed["src/main/kotlin/com/example/Bar.kt"]["lines"]["pct"] == 75.0


def test_main_with_no_matching_glob_prints_empty_object(tmp_path, monkeypatch, capsys):
    import runpy

    monkeypatch.setattr(
        "sys.argv",
        ["parse_cobertura.py", str(tmp_path / "nothing-here-*.xml")],
    )
    runpy.run_path(_MODULE_PATH, run_name="__main__")
    out = capsys.readouterr().out.strip()
    assert json.loads(out) == {}
