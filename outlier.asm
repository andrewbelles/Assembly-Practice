section .note.GNU-stack noalloc noexec nowrite progbits

section .rodata
  format_float db "%f", 0 
  format_str   db "%s", 10, 0

section .text
  extern sprintf, printf 
  global main 
  
; Program follows libc convention for commandline arguments
;   [argc] [argv[0]] [argv[1]] ... 
;   rdi <= argc 
;   rsi <= *argv[]

main:

  ; check argument count 
  cmp rdi, 2
  jl argcError 

  mov rbx, [rsi + 8]          ; argv[1] is 8 bytes offset from rsi 

  ; push r12

  ; ask os for 512 bytes for heap
  mov rax, 9 
  xor rdi, rdi
  mov rsi, 512                ; bytes to allocate 
  mov rdx, 3 
  mov r10, 34
  mov r8, -1
  xor r9, r9
  syscall                     ; address to start of heap stored at rax

  ; check output 
  test rax, rax
  js heapError

  mov r12, rax                ; store address to heap 
  
  ; open file 
  mov rax, 2                  ; sys_open
  mov rdi, rbx
  xor rsi, rsi                ; read mode  
  syscall

  ; check return value of syscall
  cmp rax, 0
  jl fileError 
  mov [r12], rax              ; store file descriptor 

loop:

  ; read a single floating point value   
  mov rax, 0                ; sys_read
  mov rdi, [r12]            ; file descriptor
  lea rsi, [r12 + 8]        ; value buffer
  mov rdx, 4                ; 4 bytes to read 
  syscall

  cmp rax, 4
  je read

  cmp rax, 0 
  je eof

read:

  sub rsp, 8                ; realign stack to % 16

  ; place float in xmm0 register, type to format string from and call 
  movss xmm0, [r12 + 8]
  cvtss2sd xmm0, xmm0       ; convert to double 
  lea rdi, [r12 + 16]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  ; set format and variable to print and call
  lea rdi, [format_str]
  lea rsi, [r12 + 16]
  mov rax, 0
  call printf

  add rsp, 8                 ; add back to stack
  
  jmp loop

heapError:
argcError:
fileError:
readError:
  ; Exit Due to Error
  mov rdi, 1                 ; set return code
  ; pop r12                    ; realign stack
  mov rax, 60                ; sys_exit call
  syscall
eof: 

  ; Handle Exit Gracefully
  xor rdi, rdi               ; set return code
  ; pop r12                    ; realign stack
  mov rax, 60                ; sys_exit call
  syscall
