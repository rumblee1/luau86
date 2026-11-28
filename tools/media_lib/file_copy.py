"""Copy and extract files from raw FAT disk images."""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .disk import partitions, validate_fat_volume


def dos_name(name):
    if (
        not name
        or name != name.strip()
        or name.endswith(".")
        or not name.isprintable()
        or any(char in name for char in '/\\<>:"|?*[]')
        or re.fullmatch(r"(?i)CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]", name.split(".")[0])
    ):
        raise ValueError(f"Unsupported FAT name: {name!r}")
    return name


def resolve_destination(images, destination):
    match = re.fullmatch(r"(A|C|D|ide[01]:[1-4]):/(.*)", destination, re.IGNORECASE)
    if not match:
        raise ValueError("--copy-to expects A:/folder, C:/folder, D:/folder, or ide0:1:/folder")
    target, path = match.groups()
    path = path.rstrip("/")
    components = [dos_name(name) for name in path.split("/")] if path else []
    if target.upper() == "A":
        slot = "floppy0"
        if slot not in images:
            raise ValueError("A: requires a mounted floppy image")
        image = images[slot]
        validate_fat_volume(image, 0, len(image))
        return slot, 0, components
    if target.upper() in ("C", "D"):
        slot = "ide0" if target.upper() == "C" else "ide1"
        layout = {drive: partitions(image) for drive, image in images.items() if drive.startswith("ide")}
        if slot not in layout or any(len(entries) != 1 or not entries[0].is_fat for entries in layout.values()):
            raise ValueError(f"Cannot resolve {target.upper()}: to a single FAT partition. Use ide0:1:/folder or ide1:1:/folder")
        partition = layout[slot][0]
    else:
        slot, number = target.lower().split(":")
        if slot not in images:
            raise ValueError(f"No disk attached to {slot}")
        partition = next((entry for entry in partitions(images[slot]) if entry.number == int(number)), None)
        if partition is None or not partition.is_fat:
            raise ValueError(f"{slot} partition {number} is not a supported primary FAT partition")
    validate_fat_volume(images[slot], partition.offset, partition.size)
    return slot, partition.offset, components


def resolve_image_path(image, location):
    match = re.match(r"^(A|C|D|ide[01](?::[1-4])?):/", location, re.IGNORECASE)
    if not match:
        raise ValueError("Image paths must start with A:/, C:/, D:/, ide0:1:/, or ide1:1:/")
    drive = match.group(1).lower().split(":")[0]
    slot = "floppy0" if drive == "a" else ("ide1" if drive in ("d", "ide1") else "ide0")
    _, offset, components = resolve_destination({slot: image}, location)
    return offset, components


def guest_path(components):
    return "::/" + "/".join(components)


def run_mtool(tool, disk, offset, *args, check=True):
    if shutil.which(tool) is None:
        raise ValueError("Install mtools to use image file operations")
    volume = f"{disk}@@{offset}" if offset else str(disk)
    result = subprocess.run(
        [tool, "-i", volume, *args],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        errors="replace",
    )
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        target = args[-1] if args else volume
        raise ValueError(f"{tool} failed for {target}" + (f": {detail}" if detail else ""))
    return result


def copy_files(disk, offset, source, components, on_conflict="error"):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("Copy source must be a directory")
    if on_conflict not in ("error", "skip", "overwrite"):
        raise ValueError(f"Unknown conflict policy: {on_conflict}")

    def exists(path):
        return run_mtool("mdir", disk, offset, "-a", "-b", path, check=False).returncode == 0

    def ensure_directory(target):
        if not exists(f"{target}/"):
            run_mtool("mmd", disk, offset, target)

    def copy_directory(host, guest):
        for item in sorted(host.iterdir()):
            target = f"{guest}/{dos_name(item.name)}"
            if item.is_symlink():
                raise ValueError(f"Cannot copy symbolic link: {item}")
            if item.is_dir():
                ensure_directory(target)
                copy_directory(item, target)
            elif item.is_file():
                if exists(target):
                    if on_conflict == "error":
                        raise ValueError(f"Destination already exists: {target}")
                    if on_conflict == "skip":
                        continue
                    run_mtool("mcopy", disk, offset, "-o", item.resolve(), target)
                else:
                    run_mtool("mcopy", disk, offset, "-D", "s", item.resolve(), target)
            else:
                raise ValueError(f"Cannot copy {item}: expected a regular file or directory")

    run_mtool("mdir", disk, offset, "-b", "::/")
    guest = "::"
    for component in components:
        guest += "/" + component
        ensure_directory(guest)
    copy_directory(source, guest)


def extract_files(disk, offset, components, destination):
    source = "::/*" if not components else guest_path(components)
    run_mtool("mcopy", disk, offset, "-s", source, str(destination))


def copy_image_files(
    source_disk,
    source_offset,
    source_components,
    destination_disk,
    destination_offset,
    destination_components,
    recursive,
    on_conflict,
):
    source = "::/*" if not source_components else guest_path(source_components)
    is_directory = not source_components or run_mtool(
        "mdir",
        source_disk,
        source_offset,
        "-a",
        "-b",
        guest_path(source_components).rstrip("/") + "/",
        check=False,
    ).returncode == 0
    if is_directory and not recursive:
        raise ValueError("Copying a directory requires --recursive")

    with tempfile.TemporaryDirectory(prefix="luau86-copy-") as temporary:
        extracted = Path(temporary) / "files"
        extracted.mkdir()
        options = ("-s",) if recursive else ()
        run_mtool("mcopy", source_disk, source_offset, *options, source, str(extracted))
        copy_files(destination_disk, destination_offset, extracted, destination_components, on_conflict)
