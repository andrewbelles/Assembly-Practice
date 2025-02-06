section .note.GNU-stack noalloc noexec nowrite progbits

section .rodata
  format_float db "%f", 0 
  format_int   db "%d", 0
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
  jl error 

  mov rbx, [rsi + 8]          ; argv[1] is 8 bytes offset from rsi 

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
  js error

  mov r12, rax                ; store address to heap 
  
  ; open file 
  mov rax, 2                  ; sys_open
  mov rdi, rbx
  xor rsi, rsi                ; read mode  
  syscall

  ; check return value of syscall
  cmp rax, 0
  jl error 
  mov [r12], rax              ; store file descriptor 

  pxor xmm0, xmm0
  movsd [r12 + 32], xmm0      ; mean = 0.0
  movsd [r12 + 48], xmm0      ; M2   = 0.0
  xor rcx, rcx

fileLoop:

  push rcx

  ; read a single double value   
  mov rax, 0                  ; sys_read
  mov rdi, [r12]              ; file descriptor
  lea rsi, [r12 + 16]         ; value buffer
  mov rdx, 8                  ; 4 bytes to read 
  syscall

  pop rcx

  cmp rax, 8
  je calcSigma 

  cmp rax, 0 
  je eofHandle

calcSigma:

  ; find standard deviation using running total
  inc rcx                     ; count++

  ; set value and curr mean
  movsd xmm0, [r12 + 16]
  movsd xmm1, [r12 + 32]
  
  subsd xmm0, xmm1            ; delta = value - mean
  movsd [r12 + 64], xmm0      ; store delta in memory

  cmp rcx, 0 
  je error

  ; get running mean from delta / count 
  cvtsi2sd xmm1, rcx             
  divsd xmm0, xmm1
  addsd xmm0, [r12 + 32]
  movsd [r12 + 32], xmm0      ; mean += delta / count  

  movsd xmm0, [r12 + 16]
  subsd xmm0, [r12 + 32]      ; delta2 = value - mean(new)

  mulsd xmm0, [r12 + 64]      ; delta * delta2 
  addsd xmm0, [r12 + 48]
  movsd [r12 + 48], xmm0 

  jmp fileLoop

eofHandle: 
  mov [r12 + 64], rcx         ; store count 

  ; pull M2 from heap
  movsd xmm0, [r12 + 48]
  mov rax, rcx
  dec rax
  cvtsi2sd xmm1, rax

  ; sigma = sqrt(M2 / count - 1)
  divsd xmm0, xmm1
  sqrtsd xmm0, xmm0

  sub rsp, 8                  ; realign stack to % 16

  ; use standard dev in xmm0 and place type to format string from and call 
  lea rdi, [r12 + 80]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  ; set format and variable to print and call
  lea rdi, [format_str]
  lea rsi, [r12 + 80]
  mov rax, 0
  call printf

  ; load mean into string var and print 
  movsd xmm0, [r12 + 16]
  lea rdi, [r12 + 80]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  lea rdi, [format_str]
  lea rsi, [r12 + 80]
  mov rax, 0
  call printf
  
  ; load count into string var and print
  mov rdx, [r12 + 64]
  lea rdi, [r12 + 80]
  lea rsi, [format_int] 
  xor rax, rax
  call sprintf

  ; set format and variable to print and call
  lea rdi, [format_str]
  lea rsi, [r12 + 80]
  mov rax, 0
  call printf
  
  add rsp, 8                  ; add back to stack
  
  ; Handle Exit Gracefully
  xor rdi, rdi                ; set return code
  mov rax, 60                 ; sys_exit call
  syscall

error:
  ; Exit Due to Error
  mov rdi, 1                  ; set return code
  mov rax, 60                 ; sys_exit call
  syscall
