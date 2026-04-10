"""Tests for path_match module — gitignore-adjacent glob semantics."""

from path_match import path_match


class TestBasenameMode:
    def test_exact_basename_at_root(self):
        assert path_match("CHANGELOG.md", "CHANGELOG.md")

    def test_exact_basename_nested(self):
        assert path_match("plugins/sdlc/CHANGELOG.md", "CHANGELOG.md")

    def test_different_basename(self):
        assert not path_match("CHANGELOG-old.md", "CHANGELOG.md")

    def test_glob_basename_at_root(self):
        assert path_match("invoice.rb", "*.rb")

    def test_glob_basename_nested(self):
        assert path_match("app/models/invoice.rb", "*.rb")

    def test_glob_basename_wrong_ext(self):
        assert not path_match("Invoice.rbi", "*.rb")


class TestAnchoredMode:
    def test_direct_child(self):
        assert path_match("docs/specs/foo.md", "docs/specs/*.md")

    def test_nested_should_not_match(self):
        assert not path_match("docs/specs/nested/foo.md", "docs/specs/*.md")

    def test_wrong_prefix(self):
        assert not path_match("other/specs/foo.md", "docs/specs/*.md")


class TestDoubleStar:
    def test_zero_segments_at_root(self):
        assert path_match("foo.test.ts", "**/*.test.ts")

    def test_one_segment(self):
        assert path_match("src/foo.test.ts", "**/*.test.ts")

    def test_many_segments(self):
        assert path_match("src/sub/deep/foo.test.ts", "**/*.test.ts")

    def test_wrong_extension(self):
        assert not path_match("foo.test.tsx", "**/*.test.ts")

    def test_vendor_direct_child(self):
        assert path_match("vendor/lib.js", "vendor/**")

    def test_vendor_deep_nested(self):
        assert path_match("vendor/sub/lib.js", "vendor/**")

    def test_vendor_different_dir(self):
        assert not path_match("src/vendor.js", "vendor/**")


class TestMiddleDoubleStar:
    def test_zero_segments_between(self):
        assert path_match("docs/README.md", "docs/**/README.md")

    def test_one_segment_between(self):
        assert path_match("docs/a/README.md", "docs/**/README.md")

    def test_many_segments_between(self):
        assert path_match("docs/a/b/c/README.md", "docs/**/README.md")

    def test_missing_docs_prefix(self):
        assert not path_match("README.md", "docs/**/README.md")

    def test_different_prefix(self):
        assert not path_match("other/README.md", "docs/**/README.md")


class TestEdgeCases:
    def test_exact_match_no_wildcards(self):
        assert path_match("plugins/sdlc/hooks/hooks.json", "plugins/sdlc/hooks/hooks.json")

    def test_wrong_exact_match(self):
        assert not path_match(
            "plugins/sdlc/hooks/hooks.json", "plugins/sdlc/hooks/other.json"
        )

    def test_question_mark_single_char(self):
        assert path_match("file1.txt", "file?.txt")

    def test_question_mark_not_a_slash(self):
        # ? must match exactly one non-slash char — "a/b" is "a"+"/"+"b",
        # not "a"+"?"+"b" where ? is the slash.
        assert not path_match("a/b.txt", "a?b.txt")

    def test_question_mark_requires_one_char(self):
        # Basename mode — ? requires exactly one char between "file" and ".txt"
        assert not path_match("file.txt", "file?.txt")
