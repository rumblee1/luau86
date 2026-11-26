# Luau XT

Luau XT runs a 386 PC inside Roblox Studio. Bring your own bootable floppy or hard disk image and use it to run DOS, Windows 3.1, or other software that fits the emulated hardware.

## Quick start

This example boots a disk that already has DOS installed.

### 1. Gather your files

You need Python 3 and a disk image with DOS already installed.

From the project folder:

- Create `roms/` and save QEMU 10.1.0's [bios-256k.bin](https://raw.githubusercontent.com/qemu/qemu/v10.1.0/pc-bios/bios-256k.bin), [vgabios.bin](https://raw.githubusercontent.com/qemu/qemu/v10.1.0/pc-bios/vgabios.bin), and Linux's [font_8x8.c](https://raw.githubusercontent.com/torvalds/linux/v6.12/lib/fonts/font_8x8.c) there.
- Put the disk image at `images/dos.img`, or use a different path in the commands below. It must be a raw image: a sector-by-sector copy of the disk. [Supported image sizes](docs/usage.md#choose-a-disk-image)

### 2. Import the disk

From the project folder, run:

```sh
python3 tools/media.py inspect ./images/dos.img
python3 tools/media.py import-firmware --bios ./roms/bios-256k.bin --vga-bios ./roms/vgabios.bin --font ./roms/font_8x8.c
python3 tools/media.py import-disk ./images/dos.img --name "My DOS PC"
```

Check that `inspect` reports a supported IDE size and a BIOS boot signature. The firmware only needs to be imported once per checkout. The disk import creates a profile named **My DOS PC** and leaves the original image untouched.

If your Python 3 command is `python` or `py -3`, use that instead of `python3`.

### 3. Power on in Studio

Sync the project to Studio and start a Play session. Select **My DOS PC** if the profile button shows a different name, then click **Power on**. A working DOS installation should display a prompt such as `C:\>`. Type `DIR` to list the disk's files.

## What to try next

- [Add your own files to a disk](docs/usage.md#add-files-to-a-disk)
- [Attach a second drive](docs/usage.md#attach-a-second-drive)
- [Boot a preinstalled Windows 3.1 image](docs/usage.md#boot-windows-31)
- [Fix a boot problem](docs/usage.md#troubleshoot)

## Tests

The smoke test uses the Luau CLI and runs without boot media.

```sh
luau --codegen tests/smoke.luau
```

## Media and license

Imported firmware and disks live in the Git-ignored `src/media/` folder. Studio builds can include these files, so use a clean checkout before sharing a build that should not contain local media.

[Usage guide](docs/usage.md) · [MIT license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
