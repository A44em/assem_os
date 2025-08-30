org 0x7C00
bits 16

%define ENDL 0x00, 0x0A

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

    ; print hello message
    mov si, msg_hello
    call puts

    hlt

.halt:
    jmp .halt

msg_hello: db 'Hello, World!', ENDL, 0

times 510-($-$$) db 0
dw 0AA55h
