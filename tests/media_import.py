"""Regression coverage for the host-side media importer."""

import base64
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[1] / "tools" / "media.py"


def reconstruct(folder):
    index = (folder / "Index.luau").read_text()
    image = bytearray(int(re.search(r"size = (\d+)", index)[1]))
    for disk_offset, part in re.findall(r'\{ (\d+), "(Part\d+)" \}', index):
        module = (folder / f"{part}.luau").read_text()
        for chunk_offset, encoded in re.findall(r'\{ (\d+), "([^"]+)" \}', module):
            data = base64.b64decode(encoded)
            offset = int(disk_offset) + int(chunk_offset)
            image[offset : offset + len(data)] = data
    return image


class MediaImportTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.media = self.work / "media"
        self.floppy = self.work / "floppy.img"
        subprocess.run(["mformat", "-i", self.floppy, "-f", "360", "-C", "::"], check=True)
        self.original_floppy = self.floppy.read_bytes()

        self.offset = 32 * 512
        hard_disk = bytearray(512 * 1024)
        hard_disk[510:512] = b"\x55\xaa"
        struct.pack_into("<B3xB3xII", hard_disk, 446, 0x80, 0x01, 32, len(self.original_floppy) // 512)
        hard_disk[self.offset : self.offset + len(self.original_floppy)] = self.original_floppy
        self.primary = self.work / "primary.img"
        self.primary.write_bytes(hard_disk)
        self.secondary = self.work / "secondary.img"
        self.secondary.write_bytes(hard_disk)
        self.original_disk = bytes(hard_disk)

        self.files = self.work / "files"
        (self.files / "DOCS").mkdir(parents=True)
        (self.files / "DOCS" / "README.TXT").write_bytes(b"import test\r\n")

    def cli(self, *args, check=True):
        return self.run_media(*args, "--output", self.media, check=check)

    def run_media(self, *args, check=True):
        return subprocess.run(
            [sys.executable, CLI, *args],
            capture_output=True, text=True, check=check,
        )

    def put_file(self, image, offset, source, destination):
        volume = f"{image}@@{offset}" if offset else str(image)
        subprocess.run(["mcopy", "-i", volume, source, destination], check=True)

    def read_fat_file(self, image, offset, path):
        volume = f"{image}@@{offset}" if offset else str(image)
        return subprocess.check_output(["mtype", "-i", volume, path])

    def read_added_file(self, folder, offset=0):
        recovered = self.work / "recovered.img"
        recovered.write_bytes(reconstruct(folder))
        volume = f"{recovered}@@{offset}" if offset else recovered
        return subprocess.check_output(["mtype", "-i", volume, "::/EXTRAS/DOCS/README.TXT"])

    def test_copy_to_second_ide_drive(self):
        for name, target in (("Explicit", "ide1:1:/EXTRAS"), ("Letter", "D:/EXTRAS")):
            with self.subTest(target=target):
                self.cli(
                    "import-disk", self.primary, "--name", name, "--attach", self.secondary, "--slot", "ide1",
                    "--copy-from", self.files, "--copy-to", target,
                )
                profile = self.media / "Imported" / name.lower()
                self.assertEqual(reconstruct(profile / "HardDisk"), self.original_disk)
                self.assertEqual(self.read_added_file(profile / "SecondHardDisk", self.offset), b"import test\r\n")
        self.assertEqual(self.primary.read_bytes(), self.original_disk)
        self.assertEqual(self.secondary.read_bytes(), self.original_disk)

    def test_floppy_copy_and_duplicate_profile(self):
        arguments = ("import-floppy", self.floppy, "--name", "DOS", "--copy-from", self.files, "--copy-to", "A:/EXTRAS")
        self.cli(*arguments)
        profile = self.media / "Imported" / "dos"
        self.assertEqual(self.read_added_file(profile / "Floppy"), b"import test\r\n")
        self.assertEqual(self.floppy.read_bytes(), self.original_floppy)
        self.assertIn("already exists", self.cli(*arguments, check=False).stderr)

    def test_copy_to_primary_ide_drive(self):
        self.cli(
            "import-disk", self.primary, "--name", "Primary",
            "--copy-from", self.files, "--copy-to", "C:/EXTRAS",
        )
        profile = self.media / "Imported" / "primary"
        self.assertEqual(self.read_added_file(profile / "HardDisk", self.offset), b"import test\r\n")
        self.assertEqual(self.primary.read_bytes(), self.original_disk)

    def test_failed_copy_leaves_no_profile(self):
        subprocess.run(
            ["mcopy", "-i", self.floppy, self.files / "DOCS" / "README.TXT", "::/README.TXT"], check=True,
        )
        source_before = self.floppy.read_bytes()
        (self.files / "README.TXT").write_bytes(b"replacement file")
        result = self.cli(
            "import-floppy", self.floppy, "--name", "Collision", "--copy-from", self.files, "--copy-to", "A:/", check=False,
        )
        self.assertIn("Destination already exists", result.stderr)
        self.assertEqual(self.floppy.read_bytes(), source_before)
        self.assertFalse((self.media / "Imported" / "collision").exists())

    def test_list_and_extract(self):
        subprocess.run(["mmd", "-i", self.floppy, "::/DOCS"], check=True)
        self.put_file(self.floppy, 0, self.files / "DOCS" / "README.TXT", "::/DOCS/README.TXT")
        hidden_file = self.work / "hidden.txt"
        hidden_file.write_bytes(b"hidden file")
        self.put_file(self.floppy, 0, hidden_file, "::/DOCS/HIDDEN.TXT")
        subprocess.run(["mattrib", "-i", self.floppy, "+h", "::/DOCS/HIDDEN.TXT"], check=True)

        listing = self.run_media("list", self.floppy, "A:/DOCS")
        self.assertIn("README.TXT", listing.stdout)
        self.assertIn("HIDDEN.TXT", listing.stdout)
        self.assertIn("DOCS", self.run_media("list", self.floppy).stdout)

        extracted = self.work / "extracted"
        self.run_media("extract", self.floppy, "A:/DOCS", "--output", extracted)
        self.assertEqual((extracted / "DOCS" / "README.TXT").read_bytes(), b"import test\r\n")
        self.assertEqual((extracted / "DOCS" / "HIDDEN.TXT").read_bytes(), b"hidden file")
        extracted_file = self.work / "single-file"
        self.run_media("extract", self.floppy, "A:/DOCS/README.TXT", "--output", extracted_file)
        self.assertEqual((extracted_file / "README.TXT").read_bytes(), b"import test\r\n")
        self.assertIn("already exists", self.run_media(
            "extract", self.floppy, "A:/DOCS", "--output", extracted, check=False,
        ).stderr)

    def test_copy_between_images(self):
        source_volume = f"{self.primary}@@{self.offset}"
        subprocess.run(["mmd", "-i", source_volume, "::/SOURCE"], check=True)
        subprocess.run(["mmd", "-i", source_volume, "::/SOURCE/DOCS"], check=True)
        self.put_file(
            self.primary,
            self.offset,
            self.files / "DOCS" / "README.TXT",
            "::/SOURCE/DOCS/README.TXT",
        )
        source_before, destination_before = self.primary.read_bytes(), self.secondary.read_bytes()
        output = self.work / "combined.img"

        result = self.run_media(
            "copy", self.primary, "ide0:1:/SOURCE", "--to", self.secondary, "ide0:1:/DEST",
            "--output", output, "--recursive",
        )
        self.assertIn("Copied files", result.stdout)
        self.assertEqual(
            self.read_fat_file(output, self.offset, "::/DEST/SOURCE/DOCS/README.TXT"),
            b"import test\r\n",
        )
        self.assertEqual(self.primary.read_bytes(), source_before)
        self.assertEqual(self.secondary.read_bytes(), destination_before)

    def test_recursive_copy_merges_directories(self):
        source_volume = f"{self.primary}@@{self.offset}"
        destination_volume = f"{self.secondary}@@{self.offset}"
        subprocess.run(["mmd", "-i", source_volume, "::/SOURCE"], check=True)
        subprocess.run(["mmd", "-i", source_volume, "::/SOURCE/DOCS"], check=True)
        self.put_file(
            self.primary,
            self.offset,
            self.files / "DOCS" / "README.TXT",
            "::/SOURCE/DOCS/README.TXT",
        )
        new_file = self.work / "new.txt"
        new_file.write_bytes(b"new source file")
        self.put_file(self.primary, self.offset, new_file, "::/SOURCE/NEW.TXT")

        subprocess.run(["mmd", "-i", destination_volume, "::/SOURCE"], check=True)
        subprocess.run(["mmd", "-i", destination_volume, "::/SOURCE/DOCS"], check=True)
        existing_file = self.work / "existing.txt"
        existing_file.write_bytes(b"keep existing file")
        self.put_file(
            self.secondary,
            self.offset,
            existing_file,
            "::/SOURCE/DOCS/README.TXT",
        )
        output = self.work / "merged.img"
        self.run_media(
            "copy", self.primary, "C:/SOURCE", "--to", self.secondary, "C:/",
            "--output", output, "--recursive", "--on-conflict", "skip",
        )
        self.assertEqual(
            self.read_fat_file(output, self.offset, "::/SOURCE/DOCS/README.TXT"),
            b"keep existing file",
        )
        self.assertEqual(
            self.read_fat_file(output, self.offset, "::/SOURCE/NEW.TXT"),
            b"new source file",
        )

    def test_copy_volume_root_includes_hidden_files(self):
        source_file = self.work / "root.txt"
        source_file.write_bytes(b"root file")
        self.put_file(self.floppy, 0, source_file, "::/ROOT.TXT")
        hidden_file = self.work / "hidden-root.txt"
        hidden_file.write_bytes(b"hidden root file")
        self.put_file(self.floppy, 0, hidden_file, "::/HIDDEN.TXT")
        subprocess.run(["mattrib", "-i", self.floppy, "+h", "::/HIDDEN.TXT"], check=True)
        subprocess.run(["mmd", "-i", self.floppy, "::/APPS"], check=True)
        self.put_file(self.floppy, 0, self.files / "DOCS" / "README.TXT", "::/APPS/README.TXT")

        output = self.work / "root-copy.img"
        self.run_media(
            "copy", self.floppy, "A:/", "--to", self.primary, "C:/",
            "--output", output, "--recursive",
        )
        self.assertEqual(self.read_fat_file(output, self.offset, "::/ROOT.TXT"), b"root file")
        self.assertEqual(self.read_fat_file(output, self.offset, "::/HIDDEN.TXT"), b"hidden root file")
        self.assertEqual(
            self.read_fat_file(output, self.offset, "::/APPS/README.TXT"),
            b"import test\r\n",
        )

    def test_copy_conflict_policies(self):
        self.put_file(self.primary, self.offset, self.files / "DOCS" / "README.TXT", "::/README.TXT")
        subprocess.run(
            ["mattrib", "-i", f"{self.primary}@@{self.offset}", "+h", "::/README.TXT"],
            check=True,
        )
        source = self.work / "replacement.txt"
        source.write_bytes(b"existing destination")
        self.put_file(self.secondary, self.offset, source, "::/README.TXT")
        subprocess.run(
            ["mattrib", "-i", f"{self.secondary}@@{self.offset}", "+h", "::/README.TXT"],
            check=True,
        )
        output = self.work / "copy-error.img"
        arguments = ("copy", self.primary, "C:/README.TXT", "--to", self.secondary, "C:/", "--output")

        failed = self.run_media(*arguments, output, check=False)
        self.assertIn("Destination already exists", failed.stderr)
        self.assertFalse(output.exists())

        skipped = self.work / "copy-skip.img"
        self.run_media(*arguments, skipped, "--on-conflict", "skip")
        self.assertEqual(self.read_fat_file(skipped, self.offset, "::/README.TXT"), b"existing destination")

        overwritten = self.work / "copy-overwrite.img"
        self.run_media(*arguments, overwritten, "--on-conflict", "overwrite")
        self.assertEqual(self.read_fat_file(overwritten, self.offset, "::/README.TXT"), b"import test\r\n")

    def test_replace_text_creates_a_copy(self):
        startup = self.work / "AUTOEXEC.BAT"
        startup.write_bytes(b"@ECHO OFF\r\nWIN /S\r\n")
        self.put_file(self.primary, self.offset, startup, "::/AUTOEXEC.BAT")
        output = self.work / "windows-enhanced.img"

        self.run_media(
            "replace-text", self.primary, "C:/AUTOEXEC.BAT",
            "--old", "WIN /S", "--new", "WIN /3", "--output", output,
        )
        self.assertEqual(
            self.read_fat_file(output, self.offset, "::/AUTOEXEC.BAT"),
            b"@ECHO OFF\r\nWIN /3\r\n",
        )
        self.assertEqual(
            self.read_fat_file(self.primary, self.offset, "::/AUTOEXEC.BAT"),
            b"@ECHO OFF\r\nWIN /S\r\n",
        )

    def test_replace_text_requires_one_match(self):
        startup = self.work / "AUTOEXEC.BAT"
        startup.write_bytes(b"WIN /S\r\nWIN /S\r\n")
        self.put_file(self.primary, self.offset, startup, "::/AUTOEXEC.BAT")
        output = self.work / "invalid.img"
        result = self.run_media(
            "replace-text", self.primary, "C:/AUTOEXEC.BAT",
            "--old", "WIN /S", "--new", "WIN /3", "--output", output, check=False,
        )
        self.assertIn("Expected one occurrence", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
