org 0x7C00
bits 16

jmp short start
nop

; --- FAT12 header ---
bdb_oem: db 'OEMID123'
bdb_bytes_per_sector: dw 512
bdb_sectors_per_cluster: db 1
bdb_reserved_sectors: dw 1
bdb_num_fats: db 2
bdb_root_entries: dw 0xE0
bdb_total_sectors_short: dw 2880
bdb_media_descriptor: db 0xF0
bdb_sectors_per_fat: dw 9
bdb_sectors_per_track: dw 18
bdb_num_heads: dw 2
bdb_hidden_sectors: dd 0
bdb_total_sectors_long: dd 0

ebr_physical_drive_number: db 0
ebr_signature: db 0x29
ebr_volume_id: dd 0x12345678
ebr_volume_label: db 'ASSEMOS    '
ebr_file_system_type: db 'FAT12   '
ebr_system_id: db 0x00

; --- Bootloader code ---
start:
    mov ax, 0x0000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    push es
    push word .after
    retf

.after:
    mov [ebr_physical_drive_number], dl

    ;read drive parameters
    push es
    mov ah, 0x08
    int 0x13
    jc floppy_error
    pop es

    and cl, 0x3F        ; Mask out upper bits to get sector number
    xor ch, ch         ; Clear cylinder high byte
    mov [bdb_sectors_per_track], cx

    inc dh               ; Heads are 1-based
    mov [bdb_num_heads], dh

    mov ax, [bdb_sectors_per_fat]
    mov bl, [bdb_num_fats]
    xor bh, bh
    mul bx
    add ax, [bdb_reserved_sectors]
    push ax

    mov ax, [bdb_sectors_per_fat]
    shl ax, 5
    xor dx, dx
    div word [bdb_bytes_per_sector]

    test dx, dx
    jz .root_dir_after
    inc ax

.root_dir_after:
    mov cl, al
    pop ax
    mov dl, [ebr_physical_drive_number]
    mov bx, buffer
    call disk_read

    xor bx, bx
    mov di, buffer

.search_kernel:
    mov si, file_name
    mov cx, 11
    push di
    repe cmpsb
    pop di
    je .found_kernel
    add di, 32
    inc bx
    cmp bx, [bdb_root_entries]
    jl .search_kernel
    jmp kernel_not_found_error

.found_kernel:
    mov ax, [di + 26]      ; first cluster
    mov [file_cluster], ax
    
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_physical_drive_number]
    call disk_read         ; read FAT table

    mov bx, FILE_LOAD_ADDR
    mov es, bx
    mov bx, FILE_OFFSET

.load_kernel_loop:
    mov ax, [file_cluster]
    add ax, 31

    mov cl, 1
    mov dl, [ebr_physical_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]


    ; assume [file_cluster] contains current cluster (word)
    ; buffer contains FAT table read earlier (byte array)
    ; result next cluster returned in AX

    mov ax, [file_cluster]    ; AX = current cluster
    mov bx, ax                ; BX = cluster (we'll build offset in BX)
    shr ax, 1                 ; AX = cluster / 2
    add bx, ax                ; BX = cluster + (cluster/2)  == offset
    mov si, buffer
    add si, bx                ; SI -> buffer + offset
    mov ax, [ds:si]           ; read word (two bytes) from FAT table

    mov dx, [file_cluster]    ; DX = cluster copy for testing LSB
    test dx, 1
    jz .even

    ; odd cluster: take high 12 bits
    shr ax, 4
    jmp .next_cluster_after

.even:
    ; even cluster: take low 12 bits
    and ax, 0x0FFF

.next_cluster_after:
    ; AX now = next cluster (12-bit value)
    cmp ax, 0xFF8
    jae .read_finish

    mov [file_cluster], ax
    jmp .load_kernel_loop

.read_finish:
    mov dl, [ebr_physical_drive_number]

    mov ax, FILE_LOAD_ADDR
    mov ds, ax
    mov es, ax
    mov ss,ax
    mov sp,0x7C00

    jmp FILE_LOAD_ADDR:FILE_OFFSET

    jmp wait_key_and_reboot

    cli
    hlt

kernel_not_found_error:
    mov si, msg_file_not_found
    call puts
    jmp wait_key_and_reboot

floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

wait_key_and_reboot:
    mov ah, 0
    int 0x16
    jmp 0xFFFF:0x0000

.halt:
    cli
    halt

puts:
    push si
    push ax
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp .loop
.done:
    pop ax
    pop si
    ret
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

file_name: db 'KERNEL  BIN'
file_cluster: dw 0
file_size: dw 0
fat_start_lba: dw 0
root_start_lba: dw 0
root_dir_sectors: dw 0
data_start_lba: dw 0
FILE_LOAD_ADDR equ 0x2000
FILE_OFFSET equ 0x0000

msg_file_not_found: db 'NO KERNEL', 0
msg_read_failed: db 'DISK ERR', 0
msg_searching: db 'Se', 0
msg_comparing: db '.', 0

times 510-($-$$) db 0
dw 0xAA55

buffer: 
