"""Import your own firmware and boot disk images into Luau86."""

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import tempfile

from media_lib.disk import BOOT_SIGNATURE, FLOPPY_SIZE, partitions, read_image, validate_fat_volume
from media_lib.file_copy import copy_files, resolve_destination
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
    slot = "floppy0" if args.image.stat().st_size == FLOPPY_SIZE else "ide0"
    image = read_image(args.image, slot)
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
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            inspect_image(args)
        elif args.command == "import-firmware":
            destination = args.output / "Firmware"
            with stage_import(args.output, destination) as staged:
                write_firmware(staged, args.bios, args.vga_bios, args.font)
            print(f"Imported firmware to {destination}")
        else:
            import_profile(args)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
