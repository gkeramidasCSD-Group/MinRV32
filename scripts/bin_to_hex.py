#!/usr/bin/env python3
"""
bin_to_hex.py

Convert a little-endian binary blob into newline-delimited hex words.

This is used by `scripts/build_prog.sh` to turn `.text`/`.data` binary sections
extracted from an ELF into `XXXXXXXX` words that can be consumed by the simple
VHDL memories in this repository.

Output format:
- One hex word per line
- Little-endian word assembly (LSB at lowest address)
- Zero-padded to the selected word width (default: 4 bytes -> 8 hex digits)
"""

import argparse
import pathlib


def convert(input_path: pathlib.Path, output_path: pathlib.Path, word_bytes: int = 4) -> None:
    """Read a raw binary file and write one hex word per line.

    Args:
        input_path:  Path to the raw binary blob (e.g. .text.bin).
        output_path: Destination for the newline-delimited hex output.
        word_bytes:  Number of bytes per word (default 4 -> 32-bit words).
    """
    if word_bytes <= 0:
        raise ValueError(f"word_bytes must be positive, got {word_bytes}")

    data = input_path.read_bytes()
    if len(data) == 0:
        output_path.write_text("")
        return

    # Pad the data with zero bytes so its length is a multiple of word_bytes.
    # This avoids an incomplete final word when the binary size is not aligned.
    pad = (-len(data)) % word_bytes
    if pad:
        data += b"\x00" * pad

    # Assemble each word from `word_bytes` consecutive bytes in little-endian
    # order and format it as a zero-padded lowercase hex string.
    words = []
    for i in range(0, len(data), word_bytes):
        chunk = data[i : i + word_bytes]
        value = int.from_bytes(chunk, byteorder="little", signed=False)
        width = word_bytes * 2  # two hex digits per byte
        words.append(f"{value:0{width}x}")

    # Write one word per line, with a trailing newline for POSIX compliance.
    output_path.write_text("\n".join(words) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=pathlib.Path, help="Binary input file")
    parser.add_argument("--output", required=True, type=pathlib.Path, help="Hex output file")
    parser.add_argument(
        "--word-bytes",
        type=int,
        default=4,
        help="Bytes per output word (default: 4). The output width is word_bytes*2 hex digits.",
    )
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    convert(args.input, args.output, word_bytes=args.word_bytes)


if __name__ == "__main__":
    main()
