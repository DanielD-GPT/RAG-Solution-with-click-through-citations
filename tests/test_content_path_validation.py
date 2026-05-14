"""Unit tests for the /content/<path> sanitizer.

These tests cover the path-traversal / SSRF / container-escape surface
that the backend's managed identity would otherwise expose if an
attacker could pass an arbitrary value for <path>.

Note on the container boundary: BlobManager.download_blob binds to the
single configured AZURE_STORAGE_CONTAINER, and the route handler does
not forward a `container=` override. So the sanitizer's job is to stop
*path traversal*, *control-character injection*, *URL injection*, and
*encoded-traversal* attempts. Cross-container reads are stopped by
BlobManager itself.
"""

import pytest

from app import _sanitize_content_path


@pytest.mark.parametrize(
    "value",
    [
        "Benefit_Options.pdf",
        "policies/Employee_Handbook.pdf",
        "report (final).pdf",
        "image-01.png",
        "file_v2.docx",
        "subfolder/doc.pdf",
    ],
)
def test_sanitize_accepts_safe_paths(value):
    assert _sanitize_content_path(value) == value


def test_sanitize_strips_page_fragment():
    assert _sanitize_content_path("doc.pdf#page=5") == "doc.pdf"


@pytest.mark.parametrize(
    "value",
    [
        # Path traversal
        "../secret.txt",
        "../../etc/passwd",
        "policies/../../tokens/session.json",
        "policies/./hidden.pdf",
        # Absolute paths / UNC / drive letters
        "/etc/hosts",
        "\\\\evil-server\\share\\f.txt",
        "C:/Windows/win.ini",
        # URL schemes (SSRF)
        "http://evil.example/x",
        "https://evil.example/x",
        "file:///etc/passwd",
        "//evil.example/x",
        # Query/fragment leakage
        "doc.pdf?x=1",
        # Null and CRLF injection
        "doc.pdf%00.png",
        "doc.pdf\nX-Injected: 1",
        "doc.pdf\r\n",
        # Encoded traversal
        "doc%2f..%2fsecret.pdf",
        "%2e%2e/secret.pdf",
        # Empty / dot-only
        "",
        ".",
        "..",
        # Too deep — only one nested folder allowed
        "a/b/c/d.pdf",
        # Length cap
        "a" * 300,
        # Shell metacharacters that shouldn't appear in real blob names
        "doc<script>.pdf",
        "doc|cat.pdf",
        "doc;rm.pdf",
        "doc$().pdf",
        "doc`whoami`.pdf",
    ],
)
def test_sanitize_rejects_dangerous_paths(value):
    assert _sanitize_content_path(value) is None


def test_sanitize_handles_none():
    assert _sanitize_content_path(None) is None


def test_sanitize_handles_double_encoding():
    # %2520 = encoded '%20'. We only decode once, so the leftover '%' fails the check.
    assert _sanitize_content_path("doc%2520file.pdf") is None
