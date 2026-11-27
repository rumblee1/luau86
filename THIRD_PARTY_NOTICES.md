# Third-party notices

The MIT license covers Luau86's own source code and documentation. Third-party firmware, fonts, and guest software retain their upstream terms.

| Component | Version and upstream terms |
| --- | --- |
| GLaBIOS | [v0.4.2 source and GPLv3 license](https://github.com/640-KB/GLaBIOS/tree/v0.4.2). Legacy fixtures patch the POST CPU label call, add an assembly hook, and recompute the ROM checksum. See the [hook source](guest/post-cpu.s). |
| SeaBIOS and SeaVGABIOS | Optional, unmodified 1.17.0 ROMs from [QEMU 10.1.0](https://github.com/qemu/qemu/tree/v10.1.0/pc-bios). See the [upstream source and license notices](https://qemu.googlesource.com/seabios/+/refs/tags/rel-1.17.0) and the [pinned ROM hashes](tools/media_lib/firmware.py). |
| Linux console font | [Linux v6.12 `font_8x8.c`](https://github.com/torvalds/linux/blob/v6.12/lib/fonts/font_8x8.c), marked GPL-2.0. The media builder extracts the glyph bytes. |
| FreeDOS | [1.4 Floppy Edition](https://www.freedos.org/download/), including the [kernel](https://github.com/FDOS/kernel) and [FreeCOM](https://github.com/FDOS/freecom). Optional packages have their own terms. See the package metadata. |
| GRUB Legacy and FREESCO | Legacy images use [Debian's GRUB 0.97 package](https://archive.debian.org/debian/pool/main/g/grub/) and [FREESCO 0.4.5](https://freesco.sourceforge.net/), including its Linux 2.0.40 kernel and RAM disk. The legacy Linux image also uses Debian's nano, glibc, and ncurses packages. |
| FastDoom | Optional [1.3.0 release](https://github.com/viti95/FastDoom/releases/tag/1.3.0) under GPLv2. The copy of GPLv2 in [guest/fastdoom-license.txt](guest/fastdoom-license.txt) accompanies the legacy guest media. |
| Doom 1.9 shareware, Windows, and local videos | The import tools use files supplied by the user. The source release excludes the game data, Windows disks, and video or soundtrack files. |

If you distribute a generated image or Roblox place, check the terms of the media it contains and include the applicable notices and corresponding source where required.
