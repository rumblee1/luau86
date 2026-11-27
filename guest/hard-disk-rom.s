# BIOS option ROM for the Luau86 disk adapter, at C800:0000.
# 340h–341h LBA, 342h–345h guest offset and segment, 346h sector count.
# Writing 347h starts the command. Reading 347h returns its status.
# Command 1 returns total sectors at 340h–341h and the last cylinder at 342h.
.intel_syntax noprefix
.code16
.arch i8086
.text
.byte 0x55, 0xaa, 2
init:
	pushf
	cli
	push ax
	push ds
	xor ax, ax
	mov ds, ax
	mov ax, [0x4c]
	mov [0x100], ax
	mov ax, [0x4e]
	mov [0x102], ax
	mov word ptr [0x4c], offset disk_service
	mov [0x4e], cs
	mov word ptr [0x64], offset boot_disk
	mov [0x66], cs
	mov byte ptr [0x475], 1
	pop ds
	pop ax
	popf
	retf

boot_disk:
	sti
	cld
	xor ax, ax
	mov ds, ax
	mov es, ax
	mov bx, 0x7c00
	mov cx, 1
	mov dx, 0x0080
	mov ax, 0x0201
	int 0x13
	jc boot_failed
	cmp word ptr [0x7dfe], 0xaa55
	jne boot_failed
	ljmp 0, 0x7c00
boot_failed:
	int 0x18
	iret

disk_service:
	cmp dl, 0x80
	jb floppy
	# Update CF in the original INT frame, leaving its other flags intact.
	push bp
	mov bp, sp
	cmp dl, 0x80
	jne invalid
	cmp ah, 8
	je geometry
	cmp ah, 0x15
	je disk_type
	cmp ah, 1
	jbe success
	cmp ah, 2
	jb invalid
	cmp ah, 4
	jbe transfer
invalid:
	mov ah, 1
	or word ptr [bp + 6], 1
	jmp finish
success:
	xor ah, ah
good_status:
	and word ptr [bp + 6], 0xfffe
finish:
	pop bp
	iret

floppy:
	int 0x40
	push bp
	mov bp, sp
	jc floppy_error
	jmp good_status
floppy_error:
	or word ptr [bp + 6], 1
	jmp finish

geometry:
	call query_geometry
	mov ch, dl      # Last cylinder returned by the controller.
	mov cl, 32      # Sectors per track.
	mov dx, 0x0f01  # Last head 15 and one hard drive.
	jmp success
disk_type:
	call query_geometry
	mov dx, ax      # Sector count fits in DX, with CX zero.
	xor cx, cx
	mov ah, 3
	jmp good_status

query_geometry:
	mov dx, 0x347
	mov al, 1
	out dx, al
	mov dx, 0x340
	in al, dx
	mov ah, al
	inc dx
	in al, dx
	xchg al, ah
	inc dx
	push ax
	in al, dx
	mov dl, al
	pop ax
	ret

transfer:
	push bx
	push cx
	push dx
	push si
	push ax
	mov si, bx
	mov bl, al
	xor bh, bh
	test bl, bl
	jz transfer_error
	test ch, 0x80   # The adapter uses a 16-bit LBA.
	jnz transfer_error
	test cl, 0xc0
	jnz transfer_error
	cmp dh, 16
	jae transfer_error
	cmp cl, 1
	jb transfer_error
	cmp cl, 32
	ja transfer_error
	xor ah, ah
	mov al, ch
	mov dl, 16
	mul dl
	xor dl, dl
	xchg dl, dh
	add ax, dx
	mov dx, 32
	mul dx
	xor ch, ch
	dec cx
	add ax, cx
	mov dx, 0x340
	out dx, al
	inc dx
	mov al, ah
	out dx, al
	inc dx
	mov ax, si
	out dx, al
	inc dx
	mov al, ah
	out dx, al
	inc dx
	mov ax, es
	out dx, al
	inc dx
	mov al, ah
	out dx, al
	inc dx
	mov al, bl
	out dx, al
	inc dx
	pop ax
	push ax
	mov al, ah
	out dx, al
	in al, dx
	test al, al
	jnz transfer_error

transfer_done:
	pop ax
	pop si
	pop dx
	pop cx
	pop bx
	jmp success
transfer_error:
	pop ax
	pop si
	pop dx
	pop cx
	pop bx
	xor al, al
	mov ah, 4
	or word ptr [bp + 6], 1
	jmp finish

.org 1023, 0
.byte 0    # Image preparation sets the additive checksum.
