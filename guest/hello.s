.intel_syntax noprefix
.code16
.arch i8086
.text

	mov dx, offset message + 0x100
	mov ah, 0x09
	int 0x21
	mov ax, 0x4c00
	int 0x21
message: .ascii "Hello from Luau86!\r\n$"
