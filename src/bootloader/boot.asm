org 0x7C00
bits 16

%define ENDL 0x00, 0x0A

;
;FAT12 header
;

jmp short start
nop

bdb_oem: db 'OEMID123' ; OEM ID
bdb_bytes_per_sector: dw 512 ; bytes per sector
bdb_sectors_per_cluster: db 1 ; sectors per cluster
bdb_reserved_sectors: dw 1 ; reserved sectors
bdb_num_fats: db 2 ; number of FATs
bdb_root_entries: dw 0xE0 ; max number of root directory entries 
bdb_total_sectors_short: dw 2880 ; total sectors (if less than 65536)
bdb_media_descriptor: db 0xF0 ; media descriptor
bdb_sectors_per_fat: dw 9 ; sectors per FAT
bdb_sectors_per_track: dw 18 ; sectors per track
bdb_num_heads: dw 2 ; number of heads
bdb_hidden_sectors: dd 0 ; hidden sectors
bdb_total_sectors_long: dd 0 ; total sectors (if more than 655

; Extended Boot Record
ebr_physical_drive_number: db 0 ; physical drive number
ebr_signature: db 0x29 ; extended boot signature
ebr_volume_id: dd 0x12345678 ; volume ID
ebr_volume_label: db 'ASSEMOS    ' ; volume label
ebr_file_system_type: db 'FAT12   ' ; file system type
ebr_system_id: db 0x00 ; bootable flag

;
; Bootloader code
;


start:
    jmp main

; print a string to the screen
; Params:
;   ds:si - pointer to the string

puts:
    ; save registers we will modify
    push si
    push ax

.loop:
    lodsb     ;loads next character in al
    or al, al  ;verify if next character is null
    jz .done   ;if so, we are done

    mov ah, 0x0E ; teletype output function
    int 0x10     ; call BIOS video interrupt
    jmp .loop

.done:
    pop ax
    pop si
    ret

main:
    ; set up segment registers
    mov ax, 0x0000
    mov ds, ax
    mov es, ax

    ;setup stack
    mov ss, ax
    mov sp, 0x7C00

    ; read some sectors from disk into memory
    ; BIOS should set dl to drive number
    mov [ebr_physical_drive_number], dl ; store drive number

    mov ax, 1        ; LBA address to read from
    mov cl, 1        ; number of sectors to read
    mov bx, 0x7E00 ; buffer to read into

    call disk_read

    ; print hello message
    mov si, msg_hello
    call puts

    cli
    hlt

;
; Error handling
;
floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

wait_key_and_reboot:
    ; wait for a key press
    mov ah, 0
    int 0x16    ; BIOS keyboard interrupt  
    jmp 0xFFFF:0x0000 ; reboot the system   


.halt:
    cli 
    jmp .halt

;
; Disk Routines
;

;
; Converts an LBA address to CHS addressing
; Params:
;   ax - LBA address
; Returns:
;   cx - sector (bits 0-5), cylinder (bits 6-15)
;   dh - head

lba_to_chs:
    
    push ax
    push dx

    xor dx, dx
    div word [bdb_sectors_per_track] ; ax = LBA / sectors per track

    inc dx         ; dx = (LBA % sectors per track) + 1 = sector
    mov cx, dx     ; cx = sector

    xor dx, dx
    div word [bdb_num_heads] ; ax = (LBA / sectors per track) / num heads = cylinder
                             ; dx = (LBA / sectors per track) % num heads = head

    mov dh, dl ; dh = head
    mov ch, al ; ch = cylinder low byte
    shl ah, 6
    or cl, ah  ; cl = sector (bits 0-5) | cylinder high bits (bits 6-7)

    pop ax
    mov dl, al
    pop ax
    ret

;
; Read sectors from disk
; Params:
;   ax - LBA address
;   cl - number of sectors to read
;   dl - drive number (0x00 for floppy)
;   es:bx - buffer to read into
; Returns:
;   CF set on error
disk_read:
    push ax
    push bx
    push cx
    push dx 
    push di
    
    push cx
    call lba_to_chs ; converts LBA in ax to CHS in cx and dh
    pop ax

    mov ah, 0x02 ; BIOS read sectors function
    mov di, 3  ; number of retries

.retry:
    pusha   ; save all registers
    stc        ; set carry flag before call
    int 0x13     ; call BIOS disk interrupt
    jnc .done   ; if no error, we are done
    
    ; read failed, reset disk system
    popa
    call disk_reset

    dec di
    test di, di
    jnz .retry  ; if we have retries left, try again

.fail:
    ; all attempts failed
    jmp floppy_error

.done:
    popa

    pop ax
    pop bx
    pop cx
    pop dx 
    pop di

    ret

;
; Reset disk system
; Params:
;   dl - drive number (0x00 for floppy)
disk_reset:
    pusha
    mov ah, 0x00 ; BIOS reset disk function
    stc        ; set carry flag before call
    int 0x13     ; call BIOS disk interrupt
    jc floppy_error ; if error, handle it
    popa
    ret

msg_hello: db 'Hello, World!', ENDL, 0
msg_read_failed: db 'Read from disk failed!', ENDL, 0

times 510-($-$$) db 0
dw 0AA55h
