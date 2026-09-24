"""The limited Mach-O operations required by the pinned ARM64 game build."""
import hashlib
import struct

from .common import UserError

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_DYLIB = 6
LC_SEGMENT_64 = 0x19
LC_BUILD_VERSION = 0x32


def commands(data):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
        raise UserError("Expected a little-endian 64-bit Mach-O file.")
    count, total = struct.unpack_from("<II", data, 16)
    end = 32 + total
    if end > len(data) or count > total // 8:
        raise UserError("Invalid Mach-O load-command table.")
    offset = 32
    for _ in range(count):
        if offset + 8 > end:
            raise UserError("Truncated Mach-O load command.")
        kind, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise UserError("Invalid Mach-O load-command size.")
        yield kind, offset, bytearray(data[offset:offset + size])
        offset += size
    if offset != end:
        raise UserError("Mach-O command count/size mismatch.")


def validate_dylib(data):
    list(commands(data))
    if struct.unpack_from("<I", data, 4)[0] != CPU_TYPE_ARM64:
        raise UserError("This tool requires an ARM64 binary.")
    if struct.unpack_from("<I", data, 12)[0] != MH_DYLIB:
        raise UserError("Expected the game's dynamic library, not its launcher.")
    for kind, _, command in commands(data):
        if kind in (0x21, 0x2C) and struct.unpack_from("<I", command, 16)[0]:
            raise UserError("Encrypted binaries are not supported.")


def sections(data):
    for kind, _, command in commands(data):
        if kind != LC_SEGMENT_64:
            continue
        if len(command) < 72:
            raise UserError("Truncated Mach-O segment.")
        count = struct.unpack_from("<I", command, 64)[0]
        if 72 + count * 80 > len(command):
            raise UserError("Truncated Mach-O section table.")
        for i in range(count):
            at = 72 + i * 80
            name = command[at:at + 16].split(b"\0")[0].decode()
            size, offset = struct.unpack_from("<QI", command, at + 40)
            if offset and offset + size > len(data):
                raise UserError("Section {} exceeds the file.".format(name))
            yield name, offset, size


def code_hash(data):
    for name, offset, size in sections(data):
        if name == "__text":
            return hashlib.sha256(data[offset:offset + size]).hexdigest()
    raise UserError("Missing __text section.")


def string_command(kind, prefix, value):
    data = struct.pack("<II", kind, 0) + prefix + value.encode() + b"\0"
    data = bytearray(data.ljust((len(data) + 7) & ~7, b"\0"))
    struct.pack_into("<I", data, 4, len(data))
    return data


def replace_commands(data, updated):
    header = b"".join(updated)
    old_size = struct.unpack_from("<I", data, 20)[0]
    first = min(offset for _, offset, size in sections(data) if offset and size)
    if 32 + len(header) > first:
        raise UserError("The new load commands do not fit before the first section.")
    length = max(old_size, len(header))
    data[32:32 + length] = header.ljust(length, b"\0")
    struct.pack_into("<II", data, 16, len(updated), len(header))


def verify_fingerprint(data, expected, name):
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise UserError("Unsupported {} ARM64 binary.\nExpected SHA-256: {}\nFound: {}\n"
                        "Only the game build in data/supported-game.json is supported. No patches were applied."
                        .format(name, expected, actual))


def patch_instructions(data, patches):
    # Validate every original word before changing any of them.
    for patch in patches:
        offset = int(patch["offset"], 0)
        if offset < 0 or offset + 4 > len(data):
            raise UserError("Instruction patch is outside the binary.")
        old = struct.unpack_from("<I", data, offset)[0]
        if old != int(patch["old_word"], 0):
            raise UserError("Unexpected instruction at {}. No instruction patches were applied.".format(patch["offset"]))
    for patch in patches:
        struct.pack_into("<I", data, int(patch["offset"], 0), int(patch["new_word"], 0))
