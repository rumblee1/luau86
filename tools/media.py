"""Manage local media and import it into Luau86."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from media_lib.disk import BOOT_SIGNATURE, FLOPPY_SIZE, partitions, read_image, validate_fat_volume
from media_lib.file_copy import (
    copy_files,
    copy_image_files,
    extract_files,
    guest_path,
    resolve_destination,
    resolve_image_path,
    run_mtool,
)
from media_lib.firmware import write_firmware
from media_lib.rojo import disk_modules


DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "src" / "media"
SLOT_FOLDERS = {"ide0": "HardDisk", "ide1": "SecondHardDisk", "floppy0": "Floppy"}


@contextmanager
def stage_import(output, destination):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"{destination} already exists. Choose a different name or output folder")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".luau86-", dir=output) as temporary:
        staged = Path(temporary) / "import"
        yield staged
        destination.parent.mkdir(parents=True, exist_ok=True)
        # A concurrent successful import creates a nonempty directory, which rename cannot replace.
        staged.rename(destination)


@contextmanager
def stage_image_output(destination, image, slot):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"{destination} already exists. Choose a different output path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".luau86-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "image.img"
        staged.write_bytes(image)
        yield staged
        read_image(staged, slot)
        try:
            os.link(staged, destination)
        except FileExistsError as error:
            raise ValueError(f"{destination} already exists. Choose a different output path") from error


@contextmanager
def stage_directory_output(destination):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"{destination} already exists. Choose a different output directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".luau86-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "files"
        staged.mkdir()
        yield staged
        staged.rename(destination)


def read_volume_image(path):
    slot = "floppy0" if path.stat().st_size == FLOPPY_SIZE else "ide0"
    return slot, read_image(path, slot)


def import_profile(args):
    name = args.name.strip()
    if not name or len(name) > 80 or not name.isprintable():
        raise ValueError("--name must contain 1–80 printable characters")
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    if not slug:
        slug = hashlib.sha256(name.encode()).hexdigest()[:16]
    if (args.copy_from is None) != (args.copy_to is None):
        raise ValueError("--copy-from and --copy-to must be used together")

    slot = "floppy0" if args.command == "import-floppy" else "ide0"
    images = {slot: read_image(args.image, slot, boot=True)}
    if slot == "ide0":
        if (args.attach is None) != (args.slot is None):
            raise ValueError("--attach and --slot must be used together")
        if args.attach is not None:
            images[args.slot] = read_image(args.attach, args.slot)

    destination = args.output / "Imported" / slug
    with stage_import(args.output, destination) as staged:
        if args.copy_from is not None:
            target, offset, folder = resolve_destination(images, args.copy_to)
            working = staged.parent / "disk.img"
            working.write_bytes(images[target])
            copy_files(working, offset, args.copy_from, folder)
            images[target] = read_image(working, target)

        staged.mkdir()
        (staged / "Profile.luau").write_text(
            f"return {json.dumps(name, ensure_ascii=False)}\n", encoding="utf-8",
        )
        for drive, image in images.items():
            disk_modules(staged / SLOT_FOLDERS[drive], image)
    print(f"Imported {name} to {destination}")


def inspect_image(args):
    slot, image = read_volume_image(args.image)
    kind = "floppy (A:)" if slot == "floppy0" else "IDE hard disk"
    print(f"{args.image}: {len(image):,} bytes, supported {kind} size")
    print("BIOS boot signature:", "present" if image[510:512] == BOOT_SIGNATURE else "absent")
    if slot == "floppy0":
        try:
            validate_fat_volume(image, 0, len(image))
        except ValueError:
            print("No recognizable FAT boot sector")
        else:
            print("FAT copy target: A:/")
    else:
        entries = partitions(image)
        if not entries:
            print("No MBR partitions found")
        for entry in entries:
            detail = "FAT" if entry.is_fat else f"type 0x{entry.kind:02x}"
            print(f"Partition {entry.number}: {detail}, offset {entry.offset:,}, size {entry.size:,} bytes")


def list_image(args):
    slot, image = read_volume_image(args.image)
    location = args.path or ("A:/" if slot == "floppy0" else "C:/")
    offset, components = resolve_image_path(image, location)
    result = run_mtool("mdir", args.image, offset, "-a", "-b", guest_path(components))
    print(result.stdout, end="")


def extract_image(args):
    slot, image = read_volume_image(args.image)
    offset, components = resolve_image_path(image, args.path)
    with stage_directory_output(args.output) as staged:
        extract_files(args.image, offset, components, staged)


def copy_image(args):
    _, source = read_volume_image(args.source_image)
    destination_image = Path(args.to[0])
    destination_path = args.to[1]
    destination_slot, destination = read_volume_image(destination_image)
    source_offset, source_components = resolve_image_path(source, args.source_path)
    destination_offset, destination_components = resolve_image_path(destination, destination_path)

    with stage_image_output(args.output, destination, destination_slot) as staged:
        copy_image_files(
            args.source_image,
            source_offset,
            source_components,
            staged,
            destination_offset,
            destination_components,
            args.recursive,
            args.on_conflict,
        )
        resolve_image_path(read_image(staged, destination_slot), destination_path)
    print(f"Copied files to {args.output}")


def replace_text(args):
    slot, image = read_volume_image(args.image)
    offset, components = resolve_image_path(image, args.path)
    if not components:
        raise ValueError("replace-text requires a file path")
    try:
        old = args.old.encode(args.encoding)
        new = args.new.encode(args.encoding)
    except LookupError as error:
        raise ValueError(f"Unknown text encoding: {args.encoding}") from error
    if not old:
        raise ValueError("--old must not be empty")

    with tempfile.TemporaryDirectory(prefix="luau86-replace-") as temporary:
        source = Path(temporary)
        file = source / components[-1]
        run_mtool("mcopy", args.image, offset, guest_path(components), str(file))
        if not file.is_file():
            raise ValueError(f"{args.path} is not a regular file")
        contents = file.read_bytes()
        occurrences = contents.count(old)
        if occurrences != 1:
            raise ValueError(f"Expected one occurrence of --old in {args.path}, found {occurrences}")
        file.write_bytes(contents.replace(old, new, 1))

        with stage_image_output(args.output, image, slot) as staged:
            copy_files(staged, offset, source, components[:-1], on_conflict="overwrite")
            resolve_image_path(read_image(staged, slot), args.path)
    print(f"Replaced text in {args.path}; wrote {args.output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    firmware = commands.add_parser("import-firmware", help="Import local SeaBIOS ROMs and the display font")
    firmware.add_argument("--bios", type=Path, required=True, help="QEMU 10.1.0 bios-256k.bin")
    firmware.add_argument("--vga-bios", type=Path, required=True, help="QEMU 10.1.0 vgabios.bin")
    firmware.add_argument("--font", type=Path, required=True, help="2048 raw glyph bytes or Linux font_8x8.c")
    firmware.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Media folder (default: src/media)")

    disk = commands.add_parser("import-disk", help="Import a raw IDE boot disk")
    disk.add_argument("--attach", type=Path, help="Optional second raw image")
    disk.add_argument("--slot", choices=["ide1", "floppy0"], help="Drive for the attached image")
    floppy = commands.add_parser("import-floppy", help="Import a 360 KiB raw boot floppy")
    for command in (disk, floppy):
        command.add_argument("image", type=Path)
        command.add_argument("--name", required=True, help="Profile title shown in Studio")
        command.add_argument("--copy-from", type=Path, help="Host directory to copy recursively")
        command.add_argument("--copy-to", help="FAT destination such as C:/EXTRAS or ide1:1:/EXTRAS")
        command.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Media folder (default: src/media)")

    inspect = commands.add_parser("inspect", help="Show image size, boot signature, and MBR partitions")
    inspect.add_argument("image", type=Path)
    list_command = commands.add_parser("list", help="List files on a FAT volume")
    list_command.add_argument("image", type=Path)
    list_command.add_argument("path", nargs="?", help="FAT path such as C:/WINDOWS (defaults to the volume root)")

    extract = commands.add_parser("extract", help="Extract a file or directory from a FAT volume")
    extract.add_argument("image", type=Path)
    extract.add_argument("path", help="FAT path such as C:/WINDOWS/CONFIG.SYS")
    extract.add_argument("--output", type=Path, required=True, help="New host directory for the extracted files")

    copy = commands.add_parser("copy", help="Copy files between FAT disk images")
    copy.add_argument("source_image", type=Path)
    copy.add_argument("source_path", help="Source FAT path such as C:/EXTRAS")
    copy.add_argument("--to", nargs=2, metavar=("IMAGE", "PATH"), required=True, help="Destination image and FAT path")
    copy.add_argument("--output", type=Path, required=True, help="New destination image to create")
    copy.add_argument("--recursive", action="store_true", help="Copy directory trees")
    copy.add_argument(
        "--on-conflict",
        choices=("error", "skip", "overwrite"),
        default="error",
        help="How to handle existing destination files (default: error)",
    )

    replace = commands.add_parser("replace-text", help="Replace one exact text occurrence in a FAT file")
    replace.add_argument("image", type=Path)
    replace.add_argument("path", help="FAT file path such as C:/AUTOEXEC.BAT")
    replace.add_argument("--old", required=True, help="Text that must occur exactly once")
    replace.add_argument("--new", required=True, help="Replacement text")
    replace.add_argument("--encoding", default="utf-8", help="Text encoding (default: utf-8)")
    replace.add_argument("--output", type=Path, required=True, help="New image to create")

    args = parser.parse_args()
    try:
        if args.command == "inspect":
            inspect_image(args)
        elif args.command == "import-firmware":
            destination = args.output / "Firmware"
            with stage_import(args.output, destination) as staged:
                write_firmware(staged, args.bios, args.vga_bios, args.font)
            print(f"Imported firmware to {destination}")
        elif args.command in ("import-disk", "import-floppy"):
            import_profile(args)
        elif args.command == "list":
            list_image(args)
        elif args.command == "extract":
            extract_image(args)
        elif args.command == "copy":
            copy_image(args)
        else:
            replace_text(args)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
