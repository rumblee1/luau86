# Usage

Start with the [quick start](../README.md#quick-start), then use this guide to choose an image, add files, or troubleshoot a boot.

## Choose a disk image

A raw disk image contains the disk's sectors in order. For a first boot, use an image you already know is bootable, such as a hard disk with DOS installed or a DOS boot floppy.

| Image | What Luau XT accepts |
| --- | --- |
| Hard disk | A raw IDE image with 1–127 whole 256 KiB cylinders. For cylinder/head/sector (CHS) addressing, use 16 heads and 32 sectors per track. |
| Floppy | A raw 360 KiB image. |

Run `inspect` to check the size, look for a BIOS boot signature, and list any MBR partitions. A boot signature is required for import as the boot disk. The operating system still needs to boot on the emulated PC.

```sh
python3 tools/media.py inspect ./images/dos.img
```

If you're starting from a 360 KiB boot floppy, import it with the same firmware from the quick start.

```sh
python3 tools/media.py import-floppy ./images/dos-boot.img --name "DOS floppy"
```

The importer writes its output to `src/media/`. Use `--output` to write elsewhere, for example to try an import without adding a profile to Studio. When you're importing firmware, the font can be Linux's `font_8x8.c` or a raw 2,048-byte font with 256 eight-row glyphs.

### What happens when you restart?

**Restart** keeps changes made to the emulated disks while you stay on the same profile in the current Play session. Start a fresh Play session or switch profiles to load a fresh copy from the imported image.

## Add files to a disk

Install `mtools` on your computer. Put a file named `README.TXT` in `./my-files`, then run this command with a DOS disk that has one primary FAT partition.

```sh
python3 tools/media.py import-disk ./images/dos.img --name "DOS with my files" --copy-from ./my-files --copy-to C:/EXTRAS
```

The importer copies the folder's contents, including subfolders, onto a copy of the disk. Start a new Play session, boot **DOS with my files**, and check for the file from the DOS prompt.

```dos
DIR C:\EXTRAS
```

Use `A:/EXTRAS` for a FAT floppy. For hard disks, file copying works with primary FAT partitions in a master boot record (MBR). Files on the original disk image stay intact.

## Attach a second drive

Use `--attach` with `--slot ide1` for a second hard disk, or `--slot floppy0` for a 360 KiB floppy. In this example, DOS boots from `dos.img` and the tool copies files into the first FAT partition on `data.img`.

```sh
python3 tools/media.py import-disk ./images/dos.img --name "DOS with a data disk" --attach ./images/data.img --slot ide1 --copy-from ./my-files --copy-to ide1:1:/EXTRAS
```

`ide1:1:/EXTRAS` means the second IDE disk, partition 1, folder `EXTRAS`. You can use `C:/EXTRAS` for the first disk or `D:/EXTRAS` for the second when each attached IDE disk has one primary FAT partition. Use an explicit slot and partition number for other layouts. DOS assigns the drive letters you see after boot.

## Boot Windows 3.1

Start with a compatible raw hard disk image that already has DOS and Windows 3.1 installed.

```sh
python3 tools/media.py import-disk ./images/windows31.img --name "Windows 3.1"
```

Start a new Play session and power on **Windows 3.1**. The disk follows its existing startup settings. If it starts at a DOS prompt, type `WIN /S` to start Windows in Standard Mode.

The Windows profile presents a Microsoft serial mouse on COM1 (03F8h, IRQ4). Move or click over the guest display. Apps can use a serial driver such as CuteMouse with `CTMOUSE /S1`. [CuteMouse manual](https://github.com/FDOS/mouse/blob/master/ctmouse.txt)

To configure waveform audio, open **Control Panel → Drivers → Add**, choose **Creative Labs Sound Blaster 1.5**, and use I/O port **220**, **IRQ 5**, and **DMA 1**. If prompted for the driver disk, enter `C:\SETUP` or point to Windows 3.1 Disk 3. Restart Windows and open `C:\WINDOWS\CHIMES.WAV` in Media Player. Waveform audio uses the emulator's shared Sound Blaster PCM output. [Microsoft driver selection](https://jeffpar.github.io/kbarchive/kb/082/Q82583/) · [Microsoft SYSTEM.INI settings](https://mskb.pkisolutions.com/kb/84752)

## Troubleshoot

| What you see | What to check |
| --- | --- |
| The profile is missing in Studio | Check that the import succeeded and wrote to `src/media/`, then start a fresh Play session. With only one available profile, Studio shows its name above **Power on**. |
| Studio says the firmware is missing | Run `import-firmware` with both QEMU 10.1.0 ROM files and the font from the quick start, then start a fresh Play session. |
| The image size is rejected | Run `inspect` and compare the image to the [supported sizes](#choose-a-disk-image). If your image is inside a ZIP archive, extract it first. Use `import-floppy` for a 360 KiB boot floppy. |
| SeaBIOS starts but DOS never appears | Check that the image has a working boot sector and a bootable OS. If you attached a second disk, try importing the boot disk by itself to narrow down the problem. |
| A destination file already exists | Pick another destination folder or change the filename in `./my-files`. The import stops on a collision. |
| The profile name already exists | Use a different `--name` to create a new profile alongside it. |

## FreeDOS apps, games, and media

If you already have a Luau XT FreeDOS library disk or demo floppy, boot it to run the included apps.

```dos
BMPVIEW SAMPLE.BMP
VGACLIP DEMO.VCL
```

`BMPVIEW` accepts uncompressed, indexed 8-bit BMPs up to 320×200. Press any key to close it. `VGACLIP` plays silent monochrome video at up to 9.1 frames per emulated second. Press Esc to return to DOS. Both run on the guest CPU and draw through VGA memory. The Roblox display uses EditableImage.

### VGA library

In **FreeDOS**, type `VGA` at `C:\>` to list the installed games, tools, and pictures.

| Command | Controls |
| --- | --- |
| `GAMES\ORBIT` | Arrow keys steer, and Space brakes. Collect eight yellow beacons and avoid the red sweeper. |
| `GAMES\SIGNAL` | Arrow keys move between tiles. Space or Enter reveals a tile. Find eight matching pairs. |
| `APPS\PIXEL` | Arrow keys move. Keys 0–8 select a color, and Space paints. S saves a new `SKETCH.BMP` in the current directory. The status light is green on success and red on failure, including when a sketch already exists. Open it with `BMPVIEW SKETCH.BMP`. |
| `APPS\PALETTE` | Arrow keys browse 256 color swatches. Enter prints the selected palette index and returns to DOS. |
| `BMPVIEW PICS\SUNSET.BMP` | View a mountain sunset. |
| `BMPVIEW PICS\NEBULA.BMP` | View a ringed planet. |

Press Esc to exit games and tools. Any key closes a picture. Guest writes such as `SKETCH.BMP` last for the current Play session, including restarts within that session.

### Play a local video

If your disk contains `VGACLIP.COM`, copy an existing `.VCL` file into its FAT partition and run `VGACLIP VIDEO.VCL` using the copied file's name. If your disk has the `BADAPPLE` launcher, type `BADAPPLE` from the DOS prompt. Press Esc to exit the player.

The player accepts 128×80 monochrome clips and doubles the pixels on both axes. Sound Blaster playback supports 20 kHz mono soundtracks and earlier 8 kHz clips.

### Doom

On disks with the Luau XT Doom launchers, run `DOOMFAST` for a smaller low-detail view with two digital sound channels, or `DOOMFAST -NOSOUND` to disable sound. `DOOMTINY -NOSOUND` uses a 96×48 viewport. On disks with FastDoom, run `FASTDOOM`. Arrow keys move and turn, Ctrl fires, and Space opens doors. Press F10 and then Y to quit.

From `C:\DOOM`, run `DOOM -NOMUSIC -NOMOUSE -WARP 1 1` to launch with your regular Doom configuration. Startup can take time while the DOS extender initializes and the game reads the WAD.

### Guest audio

The PC speaker works through PIT channel 2 and port 61h. The 386 profiles also provide Sound Blaster 2.0-compatible 8-bit mono playback at port 220h, IRQ 5, DMA 1. The VGA disk sets `BLASTER=A220 I5 D1 T3` and gives a fresh Doom install these settings for digital sound effects. For an existing Doom configuration, set the sound effects device to **Sound Blaster**, with those port, IRQ, and DMA values. Use `-NOMUSIC` for Doom's digital effects. [Creative Sound Blaster hardware guide](https://pdos.csail.mit.edu/6.1810/2017/readings/hardware/SoundBlaster.pdf)

In a Studio Play session, run `BEEP` from the **FreeDOS** prompt for a short tone. In the Client explorer, `PlayerGui.LuauXT` shows `AudioStatus`. `Studio PCM` means Roblox is consuming PCM samples. `PC speaker only` uses a built-in Roblox tone to approximate the PC speaker, and `AudioDetail` shows why the PCM path is unavailable. Set `AudioVolume` between 0 and 1 to adjust or mute either path. `AudioUnderruns` counts times the guest sample queue emptied and had to refill during PCM playback. `AudioWriterUnderruns` counts times the Roblox output buffer was found empty during playback. The player adjusts its output reserve to cushion uneven Roblox frames and measures guest speed against elapsed time so tempo can adjust while preserving pitch.

Bad Apple and Doom's digital sounds require `AudioStreamWriter`. Roblox restricts it to Studio outside Team Create, and its availability depends on the Studio build and feature rollout. [Roblox audio output reference](https://create.roblox.com/docs/reference/engine/classes/AudioStreamWriter) · [Roblox engine team rollout notes](https://devforum.roblox.com/t/release-notes-for-747/4985911?page=3)

## Hardware and boot profiles

| Component | Luau XT |
| --- | --- |
| CPU | 386 core with the additional instructions used by the stock SeaBIOS build |
| Memory | 640 KiB conventional RAM and 15 MiB extended RAM |
| Firmware | SeaBIOS 1.17.0 and SeaVGABIOS |
| Storage | One 360 KiB floppy and up to two IDE disks |
| Video | 80×25 text, 320×200 indexed graphics, and 640×480 planar graphics |
| Input and sound | PC keyboard, Microsoft serial mouse on COM1, PC speaker, and Sound Blaster-compatible audio |

Luau XT uses the original SeaBIOS and SeaVGABIOS binaries from QEMU 10.1.0. The media builder checks both SHA-256 digests. The emulator provides Intel 440FX shadow memory, QEMU's firmware configuration ports, and IDE. The client scheduler paces guest time against the 1.193 MHz PIT. [SeaBIOS source](https://qemu.googlesource.com/seabios/+/refs/tags/rel-1.17.0) · [QEMU firmware configuration](https://www.qemu.org/docs/master/specs/fw_cfg.html)
