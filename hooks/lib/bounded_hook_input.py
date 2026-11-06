#!/usr/bin/python3
"""Read hook admission data with bounded memory and bounded transcript scanning."""

from __future__ import annotations

import errno
import json
import os
from collections.abc import Iterator, Sequence
from pathlib import Path
import stat
import sys

INPUT_BUDGET = 65_536
TRANSCRIPT_SCAN_BUDGET = 8_388_608
SCAN_CHUNK = 65_536
HUMAN_PROMPT_KIND = "human"


def transcript_relative_parts_are_allowed(parts: Sequence[str]) -> bool:
    return bool(parts) and all(part not in ("", ".", "..") for part in parts)


def transcript_raw_character_is_allowed(character: str) -> bool:
    if len(character) != 1:
        return False
    codepoint = ord(character)
    return codepoint >= 32 and (codepoint < 127 or codepoint > 159)


def transcript_raw_absolute_path_is_allowed(raw_path: str) -> bool:
    if not all(map(transcript_raw_character_is_allowed, raw_path)):
        return False
    if not raw_path.startswith("/"):
        return False
    root_marker, *components = raw_path.split("/")
    return root_marker == "" and transcript_relative_parts_are_allowed(components)


def _decode_bounded(data: bytes) -> str | None:
    if len(data) > INPUT_BUDGET:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None


def _emit_bounded(data: bytes) -> int:
    if _decode_bounded(data) is None:
        return 2
    view = memoryview(data)
    while view:
        written = os.write(1, view)
        view = view[written:]
    return 0


def _read_bounded_stdin() -> bytes | None:
    retained = bytearray()
    while len(retained) <= INPUT_BUDGET:
        chunk = os.read(0, min(4096, INPUT_BUDGET + 1 - len(retained)))
        if not chunk:
            return bytes(retained)
        retained.extend(chunk)
    return None


def _hook_object(data: bytes | None) -> dict[str, object] | None:
    if data is None or (decoded := _decode_bounded(data)) is None:
        return None
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def read_stdin() -> int:
    data = _read_bounded_stdin()
    return 2 if data is None else _emit_bounded(data)


def _read_first_record(fd: int) -> bytes | None:
    retained = bytearray()
    try:
        while len(retained) <= INPUT_BUDGET and b"\n" not in retained:
            chunk = os.read(fd, min(4096, INPUT_BUDGET + 1 - len(retained)))
            if not chunk:
                break
            retained.extend(chunk)
    except OSError as error:
        if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
            return None
        return None
    record, separator, _remainder = bytes(retained).partition(b"\n")
    if not separator and len(retained) > INPUT_BUDGET:
        return None
    return record


def _open_absolute_directory_without_symlinks(path: Path) -> int | None:
    parts = path.parts
    if not path.is_absolute() or not parts or parts[0] != "/":
        return None
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        directory_fd = os.open("/", flags)
    except OSError:
        return None
    for part in parts[1:]:
        if not transcript_relative_parts_are_allowed((part,)):
            os.close(directory_fd)
            return None
        try:
            next_fd = os.open(part, flags, dir_fd=directory_fd)
        except OSError:
            os.close(directory_fd)
            return None
        os.close(directory_fd)
        directory_fd = next_fd
    return directory_fd


def _open_contained_transcript(projects_root: Path, path: Path) -> int | None:
    root_parts = projects_root.parts
    path_parts = path.parts
    if (
        not projects_root.is_absolute()
        or not path.is_absolute()
        or path_parts[: len(root_parts)] != root_parts
    ):
        return None
    relative_parts = path_parts[len(root_parts) :]
    if (
        not transcript_relative_parts_are_allowed(relative_parts)
        or not relative_parts[-1].endswith(".jsonl")
    ):
        return None

    try:
        trusted_root = projects_root.resolve(strict=True)
    except OSError:
        return None
    directory_fd = _open_absolute_directory_without_symlinks(trusted_root)
    if directory_fd is None:
        return None
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        for part in relative_parts[:-1]:
            next_fd = os.open(part, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(
            relative_parts[-1],
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        os.close(directory_fd)
        return None
    os.close(directory_fd)
    if stat.S_ISREG(os.fstat(file_fd).st_mode):
        return file_fd
    os.close(file_fd)
    return None


def read_transcript_first_record(projects_root: Path, raw_path: str) -> int:
    if not transcript_raw_absolute_path_is_allowed(raw_path):
        return 2
    fd = _open_contained_transcript(projects_root, Path(raw_path))
    if fd is None:
        return 2
    try:
        record = _read_first_record(fd)
    finally:
        os.close(fd)
    if record is None or (decoded := _decode_bounded(record)) is None:
        return 2
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError:
        return 2
    return _emit_bounded(record) if isinstance(value, dict) else 2


def read_hook_transcript_first_record(projects_root: Path) -> int:
    hook = _hook_object(_read_bounded_stdin())
    if hook is None:
        return 2
    raw_path = hook.get("transcript_path")
    if not isinstance(raw_path, str) or not raw_path:
        return 2
    return read_transcript_first_record(projects_root, raw_path)


def _pread_exact(fd: int, length: int, offset: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    position = offset
    while remaining > 0:
        chunk = os.pread(fd, remaining, position)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
        position += len(chunk)
    return b"".join(chunks)


def _lines_backwards(fd: int, scan_budget: int) -> Iterator[bytes]:
    # Yields complete lines newest-first; a partial line at the scan boundary is
    # never yielded, so an unfinished record cannot be mistaken for a complete one.
    offset = os.fstat(fd).st_size
    scanned = 0
    carry = b""
    while offset > 0 and scanned < scan_budget:
        start = max(0, offset - SCAN_CHUNK)
        block = _pread_exact(fd, offset - start, start)
        scanned += len(block)
        offset = start
        lines = (block + carry).split(b"\n")
        carry = lines[0]
        yield from reversed(lines[1:])
    if offset == 0:
        yield carry


def _human_prompt_of(line: bytes, prompt_id: str) -> str | None:
    try:
        record = json.loads(line.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(record, dict):
        return None
    origin = record.get("origin")
    message = record.get("message")
    if (
        record.get("type") != "user"
        or record.get("promptId") != prompt_id
        or record.get("isMeta") is True
        or not isinstance(origin, dict)
        or origin.get("kind") != HUMAN_PROMPT_KIND
        or not isinstance(message, dict)
        or message.get("role") != "user"
    ):
        return None
    content = message.get("content")
    return content if isinstance(content, str) else None


def _find_human_prompt(fd: int, prompt_id: str) -> str | None:
    needle = prompt_id.encode("utf-8")
    for line in _lines_backwards(fd, TRANSCRIPT_SCAN_BUDGET):
        if needle not in line:
            continue
        prompt = _human_prompt_of(line, prompt_id)
        if prompt is None:
            continue
        # Prompts over the capture budget or containing NUL are not admitted.
        if len(line) > INPUT_BUDGET or "\0" in prompt:
            return None
        if len(prompt.encode("utf-8")) > INPUT_BUDGET:
            return None
        return prompt
    return None


def read_last_human_prompt(projects_root: Path) -> int:
    hook = _hook_object(_read_bounded_stdin())
    if hook is None:
        return 2
    raw_path = hook.get("transcript_path")
    prompt_id = hook.get("prompt_id")
    if (
        not isinstance(raw_path, str)
        or not raw_path
        or not isinstance(prompt_id, str)
        or not prompt_id
        or not transcript_raw_absolute_path_is_allowed(raw_path)
    ):
        return 2
    fd = _open_contained_transcript(projects_root, Path(raw_path))
    if fd is None:
        return 2
    try:
        prompt = _find_human_prompt(fd, prompt_id)
    finally:
        os.close(fd)
    if prompt is None:
        return 2
    payload = json.dumps(
        {"turn_id": prompt_id, "prompt": prompt},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return _emit_bounded(payload)


def main(argv: Sequence[str]) -> int:
    if argv == ["stdin"]:
        return read_stdin()
    if len(argv) == 2 and argv[0] == "hook-transcript-first-record":
        return read_hook_transcript_first_record(Path(argv[1]))
    if len(argv) == 2 and argv[0] == "claude-hook-last-human-prompt":
        return read_last_human_prompt(Path(argv[1]))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
