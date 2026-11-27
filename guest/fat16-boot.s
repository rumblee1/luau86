# FAT16 boot sector for the classic FreeDOS hard disk.
# The image builder supplies the BPB at offsets 11 through 61.
.intel_syntax noprefix
.code16
.arch i8086
.text
	jmp start
	nop
	.ascii "LUAU86  "
	.org 62
start:
	cli
	mov ax, cs
	mov ss, ax
	mov sp, 0x8000
	mov ds, ax
	mov es, ax
	sti
	cld
	mov [drive], dl

	mov ax, [28]  # Partition start (low word).
	add ax, [14]  # Reserved sectors.
	mov [fat_start], ax
	mov al, [16]  # FAT copies.
	xor ah, ah
	mul word ptr [22]
	add ax, [fat_start]
	mov [root_start], ax
	mov ax, [17]  # Root entries, 16 per sector.
	add ax, 15
	mov cl, 4
	shr ax, cl
	add ax, [root_start]
	mov [data_start], ax
	mov ax, [root_start]

find_sector:
	cmp ax, [data_start]
	jae failure
	mov bx, 0x0200
	call read_sector
	mov di, bx
	mov bp, 16
find_entry:
	cmp byte ptr [di], 0
	je failure
	push di
	mov si, offset kernel_name
	mov cx, 11
	repe cmpsb
	pop di
	je found
	add di, 32
	dec bp
	jnz find_entry
	inc ax
	jmp find_sector

found:
	mov ax, [di + 26]
	mov dx, 0x0060
	mov es, dx
	mov bp, 128

load_cluster:
	cmp ax, 2
	jb failure
	push ax
	sub ax, 2
	xor cx, cx
	mov cl, [13]  # Sectors per cluster.
	mul cx
	add ax, [data_start]
load_sector:
	dec bp
	jz failure
	xor bx, bx
	call read_sector
	inc ax
	mov dx, es
	add dx, 0x20
	mov es, dx
	loop load_sector

	pop ax
	push es
	push ds
	pop es
	xor bx, bx
	mov bl, al
	shl bx, 1
	push bx
	mov al, ah
	xor ah, ah
	add ax, [fat_start]
	mov bx, 0x0200
	call read_sector
	pop bx
	mov ax, [bx + 0x0200]
	pop es
	cmp ax, 0xfff8
	jb load_cluster
	mov dl, [drive]
	mov bl, dl
	ljmp 0x0060, 0

read_sector:
	push ax
	push cx
	push dx
	xor dx, dx
	div word ptr [24]
	mov cl, dl
	inc cl
	xor dx, dx
	div word ptr [26]
	mov ch, al
	mov dh, dl
	mov dl, [drive]
	mov ax, 0x0201
	int 0x13
	jc failure
	pop dx
	pop cx
	pop ax
	ret

failure:
	int 0x18
	cli
	hlt

drive: .byte 0
fat_start: .word 0
root_start: .word 0
data_start: .word 0
kernel_name: .ascii "KERNEL  SYS"
.org 510
.word 0xaa55
