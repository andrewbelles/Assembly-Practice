section .note.GNU-stack noalloc noexec nowrite progbits

section .rodata 
  print_iter db  "Iter    : %s",  6, 0
  print_sigma db "Sigma   : %s", 10, 0
  print_mean db  "Mean    : %s", 10, 0
  print_coun db  "Count   : %s", 10, 0
  print_outc db  "Outliers: %s", 10, 0

  print_test db "Test", 0
  print_newl db " ", 0

  ; test for andpd for absolute value
  align 16 
  mask dq 0x7FFFFFFFFFFFFFFF, 0 
  
  format_float db "%f", 0  
  format_int   db "%d", 0
  format_str   db "%s", 10, 0

section .text
  extern sprintf, printf, strtod
  global main

main:

  ; argc check 
  cmp rdi, 4
  jl error

  mov rbx, [rsi + 8]
  mov r13, [rsi + 16]
  mov rbp, [rsi + 24]

  mov rax, 9
  xor rdi, rdi
  mov rsi, 512                 
  mov rdx, 3 
  mov r10, 34
  mov r8, -1
  xor r9, r9
  syscall                     

  ; check output 
  test rax, rax
  js error

  mov r12, rax

  sub rsp, 8

  ; process threshold 
  lea rdi, [rbp]
  xor rsi, rsi 
  call strtod

  ; threshold
  movsd [r12 + 16], xmm0

  ; read file 
  mov rax, 2
  mov rdi, rbx
  xor rsi, rsi 
  syscall 

  ; check output 
  cmp rax, 0
  jl error

  ; place write fd
  mov [r12], rax 

  pxor xmm0, xmm0
  movsd [r12 + 48], xmm0              ; mean
  movsd [r12 + 64], xmm0              ; M2

  xor rcx, rcx

.loop:

  push rcx

  ; prepare read syscall
  mov rax, 0
  mov rdi, [r12]
  lea rsi, [r12 + 32]
  mov rdx, 8
  syscall 
  
  pop rcx

  cmp rax, 8
  je .sigmaCall

  cmp rax, 0 
  je .eof 

sigmaCall:
  
  ; aggregate m2 and mean
  mov rdi, rcx
  
  push rcx 

  mov rsi, [r12 + 48]
  mov rdx, [r12 + 64]
  movsd xmm0, [r12 + 32]
  call _sigma

  pop rcx

  jmp .loop

eof: 
  
  ; calc standard deviation 
  movsd xmm0, [r12 + 64]
  mov rax, rcx
  dec rax 
  cvtsi2sd xmm1, rax 
  divsd xmm0, xmm1 
  sqrtsd xmm0, xmm0 
  movsd [r12 + 64], xmm0

  ; take count and create new memory for clean loop
  ; rcx holds count 
  mov [r12 + 80], rcx
  imul rcx, 3
  imul rcx, 8

  ; syscall for array memory
  mov rax, 9
  xor rdi, rdi 
  mov rsi, rcx
  mov rdx, 3
  mov r10, 34 
  mov r8, -1
  xor r9, r9
  syscall

  test rax, rax 
  js error

  ; allocate full, clean, and outlier arrays
  mov r13, rax
  mov rcx, [r12 + 80]
  imul rcx, 8
  add rax, rcx 
  mov r14, rax
  add rax, rcx
  mov r15, rcx

  ; reset file pointer location
  mov rax, 8
  mov rdi, [r12]
  xor rsi, rsi
  xor rdx, rdx
  syscall

  xor r8, r8

  ; mean in r12 + 144
  ; m2   in r12 + 160
outlierLoop:

  cmp r8, 0 
  jne .checkEnd

  ; if first iteration calculation first threshold 
  push r8

  mov rdi, [r12 + 16]
  mov rsi, [r12 + 64]
  call _threshold

  movsd [r12 + 128], xmm0

  pop r8

  jmp .read

  .checkEnd:

  ;  check current outlier count with previous count 
  cmp r10, [r12 + 96]
  je end 

  ; reset counters used 

  xor rcx, rcx 
  xor r8, r8
  xor r9, r9
  xor r10, r10
  xor r11, r11

  ; move clean count into current count 
  mov [r12 + 112], r9
  mov [r12 + 172], r10              ; keep track of n outliers

  ; move clean array into full array 
  mov r13, r14

  ; calc stdev and move mean 
  movsd xmm0, [r12 + 160]
  dec r9
  cvtsi2sd xmm1, r9
  divsd xmm0, xmm1 
  sqrtsd xmm0, xmm0
  movsd [r12 + 64], xmm0 
  movsd xmm0, [r12 + 144]
  movsd [r12 + 48], xmm0

  push r8

  ; update threshold 
  mov rdi, [r12 + 16]
  mov rsi, [r12 + 64]
  call _threshold
  
  pop r8

  .read:
  
  push rcx
  push r8
  push r9 
  push r10
  push r11

  sub rsp, 8
  
  mov rax, 0 
  mov rdi, [r12]
  lea rsi, [r12 + 32]
  mov rdx, 8
  syscall

  add rsp, 8
  
  pop r11
  pop r10 
  pop r9 
  pop r8
  pop rcx

  mov rsi, 8
  imul rsi, rcx 
  movsd xmm0, [r12 + 32]
  movsd [r13 + rsi], xmm0

  inc rcx

  cmp rcx, [r12 + 80]
  jne .read

  ; clear count accumulated from array indexing
  xor rcx, rcx 
  je .clean

  .clean:

  mov rsi, 8 
  imul rsi, r11
  movsd xmm0, [r13 + rsi]

  inc r11 

  ; check if abs(residual) < sigma * threshold
  subsd xmm0, [r12 + 48]
  movapd xmm1, [mask]
  andpd xmm0, xmm1
  movsd xmm1, [r12 + 128]
  ucomisd xmm0, xmm1 
  jg .outlier 

  mov rbp, 8
  imul rbp, r9 
  inc r9
  movsd xmm0, [r13 + rsi]
  movsd [r14 + rbp], xmm0

  ; call sigma calculation
  mov rsi, [r12 + 48]
  mov rdx, [r12 + 64]
  movsd xmm0, [r14 + rbp] 
  call _sigma

  cmp r11, [r12 + 112]
  je .checkEnd

  jmp .clean

  .outlier:
  
  mov rbp, 8
  imul rbp, r10
  inc r10
  movsd xmm0, [r13 + rsi]
  movsd [r15 + rbp], xmm0 

  cmp r11, [r12 + 112]
  je .checkEnd

  jmp .clean

end: 
  
  ; print all outliers to file
  
  ; sysopen read file
  mov rax, 2 
  mov rdi, r13 
  mov rsi, 01h | 40h | 200h
  mov rdx, 0644
  syscall

  cmp rax, 0 
  jl error 
  mov [r12 + 8], rax

  ; should prob free memory here but oops
  xor r13, r13 
  .printloop:

  xor rdx, rdx
  mov rax, rsp
  mov rcx, 16
  div rcx 
  cmp rdx, 0 
  je .aligned 

  mov rbx, rdx 
  sub rsp, rbx 

  .aligned: 

  ; get count 
  mov rbp, 8
  imul rbp, r11
  movsd xmm0, [r15 + rbp]
  lea rdi, [r12 + 192]
  lea rsi, [format_float]
  mov rax, 1 
  call sprintf 
  
  xor rcx, rcx

  .str_len:

  cmp byte [rdi + rcx], 0 
  je .write 
  inc rcx 
  jmp .str_len

  .write: 

  mov rax, 1 
  mov rdi, [r12 + 8]
  lea rsi, [r12 + 192]
  mov rdx, rcx 
  syscall

  lea rsi, [print_newl]
  mov rdx, 1 
  syscall

  inc r13

  cmp r13, [r12 + 172]
  jl .printloop
  
  ; print final found values to user 
  ; final sigma calc 
  movsd xmm0, [r12 + 160]
  mov rcx, [r12 + 112]
  dec rcx
  cvtsi2sd xmm1, rcx
  divsd xmm0, xmm1
  movsd [r12 + 160], xmm0

  ; print outlier count 
  mov rdx, [r12 + 112]
  lea rdi, [r12 + 172]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  ; set format and variable to print and call
  lea rdi, [print_sigma]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf

  ; load mean into string var and print 
  mov rdx, [r12 + 144]
  lea rdi, [r12 + 172]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  lea rdi, [print_mean]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf
  
  ; load count into string var and print
  movsd xmm0, [r12 + 160]
  lea rdi, [r12 + 172]
  lea rsi, [format_int] 
  xor rax, rax
  call sprintf

  ; set format and variable to print and call
  lea rdi, [print_outc]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf

  ; close files
  mov rax, 3 
  mov rdi, [r12]
  syscall
  mov rdi, [r12 + 8]
  syscall 

  ; free clean and outlier arrays
  mov rbx, [r12 + 180]
  imul rbx, 8
  imul rbx, 2 

  mov rax, 11 
  mov rdi, r14
  mov rsi, rbx 
  syscall 

  ; free agg heap
  mov rax, 11 
  mov rdi, r12 
  mov rsi, 512 
  syscall 

  xor rdi, rdi
  mov rax, 60
  syscall

error: 

  ; close files
  mov rax, 3 
  mov rdi, [r12]
  syscall
  mov rdi, [r12 + 8]
  syscall 

  ; free agg heap
  mov rax, 11 
  mov rdi, r12 
  mov rsi, 512 
  syscall 

  xor rdi, rdi
  mov rax, 60
  syscall

; Aggregates M2 and mean 
;
; Registers used: 
;   rdi:  current count
;   rsi:  pointer to mean
;   rdx:  pointer to M2
;   xmm0: current value
;
_sigma: 
  
  ; pull mean and M2 from memory
  movsd xmm1, [rsi]
  movsd xmm2, [rdx]

  ; count to double
  cvtsi2sd xmm3, rdi

  ; subtract mean from current value and store in xmm4
  movsd xmm4, xmm0
  subsd xmm4, xmm1

  ; update mean with delta 
  divsd xmm4, xmm3 
  addsd xmm1, xmm4

  ; subtract new mean from valule and store in xmm5
  movsd xmm5, xmm0
  subsd xmm5, xmm1 

  ; add to M2 with delta * delta2
  mulsd xmm4, xmm5 
  addsd xmm2, xmm4

  ; place new values in memory
  movsd [rsi], xmm1
  movsd [rdx], xmm2 

  ret

; 
;  rdi: threshold
;  rsi: iter's sigma 
;
;  ret xmm0 holds threshold
;
_threshold:
  
  ; calculate threshold
  movsd xmm0, [r12 + 16]
  mulsd xmm0, [r12 + 64]

  ret
