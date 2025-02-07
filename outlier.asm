section .note.GNU-stack noalloc noexec nowrite progbits

section .rodata
  format_float db "%f", 0 
  format_int   db "%d", 0
  format_str   db "%s", 10, 0

section .text
  extern sprintf, printf, strtod
  global main 
  
; Program follows libc convention for commandline arguments
;   [argc] [argv[0]] [argv[1]] ... 
;   rdi <= argc 
;   rsi <= *argv[]

main:

  ; check argument count 
  cmp rdi, 3
  jl error 

  mov rbx, [rsi + 8]          ; argv[1] is 8 bytes offset from rsi 
  mov rpb, [rsi + 16]         ; argv[1] (threshold) is 16 bytes offset

  ; 512 bytes for aggregate values, scanf 
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

  mov r12, rax                ; store address of heap for aggregates at r12

  ; call c library string to double to process threshold (will be placed in r12 + 8 (after fd))
  lea rdi, rpb
  xor rsi, rsi
  call strtod

  movsd [r12 + 8], xmm0       ; store in low memory on heap 

  ; open file 
  mov rax, 2                  ; sys_open
  mov rdi, rbx
  xor rsi, rsi                ; read mode  
  syscall

  ; check return value of syscall
  cmp rax, 0
  jl error 
  mov [r12], rax              ; file descriptor first value in r12 

  ; full file mean, M2, count, sigma calc

  pxor xmm0, xmm0
  movsd [r12 + 32], xmm0      ; mean = 0.0
  movsd [r12 + 48], xmm0      ; M2   = 0.0
  xor rcx, rcx

  sub rsp, 8

fileLoop:

  push rcx                    ; reserve rcx through syscall

  ; read a single double value   
  mov rax, 0                  ; sys_read
  mov rdi, [r12]              ; file descriptor
  lea rsi, [r12 + 16]         ; value buffer
  mov rdx, 8                  ; 8 bytes to read 
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
  movsd xmm0, [r12 + 32]
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
  
  mov r13, [r12 + 64]
  mul r13, 3
  mul r13, 8                  ; count * 3 arrays * 8 bytes per float

  ; allocate region for arrays  
  mov rax, 9 
  xor rdi, rdi
  mov rsi, r13
  mov rdx, 3 
  mov r10, 34
  mov r8, -1
  xor r9, r9
  syscall                    

  ; allocating arrays 
  mov r13, rax                ; store arary addresses at r13, r14, r15 
  mov rbx, [r12 + 64]
  mul rbx, 8
  add rax, rbx
  mov r14, rax
  add rax, rbx
  mov r15, rax

  ; reset file pointer location 
  mov rax, 8                  ; lseek ~= fseek(fptr, 0, SEEK_SET)
  mov rdi, [r12]              ; fd
  xor rsi, rsi
  xor rdx, rdx 
  syscall

  ; init counters 
  xor r8, r8                  ; iter counter 

  ; r13 is the full array 
  ; r14 is the clean array 
  ; r15 is the outlier array 

outlierLoop:
  
  xor rcx, rcx                ; value counter  
  xor r9, r9                  ; outlier counter
  xor r10, r10                ; clean counter

  ; calculate sigma*threshold with previous sigma and place in r12 + 128
  movsd xmm0, [r12 + 8]
  mulsd xmm0, [r12 + 80]
  movsd [r12 + 128], xmm0

  cmp r8, 0 
  je readToArr
  
readLoop: 
  
  ; push counters onto stack  
  push rcx

  ; read double to agggregate heap
  mov rax, 0                  ; sys_read
  mov rdi, [r12]              
  lea rsi, [r12 + 16]         ; double buffer
  mov rdx, 8                  ; 8 bytes to read 
  syscall

  ; revert values 
  pop rcx 

  ; place value in array r13
  ; r13[i] = [r13 + rcx * 8]
  mov rsi, 8
  mul rsi, rcx
  movsd [r13 + rsi], [r12 + 16] ; iterate array r13 

  inc rcx 
  
  ; process outputs 
  cmp rcx, [r12 + 64]
  jne readLoop                ; loop till eof  
  je  arrayLoop 

arrayLoop:
  ; r8 loops to previous count (stored in rcx)
  
  ; load value from array. if abs(array - previous aggregate mean) < threshold * previous sigma add to outliers
  mov rsi, 8
  mul rsi, r8
  movsd xmm0, [r13 + rsi]

  subsd xmm0, [r12 + 32]
  andpd xmm0                ; abs(residual)

  cmp xmm0, [r12 + 128]
  jgt outlier
  
  ; load into clean arr
  mov rpb, 8
  mul rpb, r9 
  movsd [r14 + rpb], [r13 + rsi]

  inc r9

  jmp calcValues
  
outlier:

  mov rpb, 8
  mul rpb, r10
  movsd [r15 + rpb], [r13 + rsi]

  inc r10

  ; print value to file 

  jmp arrayLoop 

calcValues: ; new aggregate values are placed in a new region on the aggregate heap

  ; find standard deviation using running total
  inc rcx                     ; count++

  ; set value and curr mean
  movsd xmm0, [r14 + rbp]
  movsd xmm1, [r12 + 144]
  
  subsd xmm0, xmm1            ; delta = value - mean
  movsd [r12 + 64], xmm0      ; store delta in memory

  cmp rcx, 0 
  je error

  ; get running mean from delta / count 
  cvtsi2sd xmm1, rcx             
  divsd xmm0, xmm1
  addsd xmm0, [r12 + 144]
  movsd [r12 + 32], xmm0      ; mean += delta / count  

  movsd xmm0, [r12 + 16]
  subsd xmm0, [r12 + 80]      ; delta2 = value - mean(new)

  mulsd xmm0, [r12 + 112]      ; delta * delta2 
  addsd xmm0, [r12 + 96]
  movsd [r12 + 96], xmm0 

  cmp r8, 0 
  je readToArr

  jmp arrayLoop

printOutput:




  ; Handle Exit Gracefully
  xor rdi, rdi                ; set return code
  mov rax, 60                 ; sys_exit call
  syscall

error:
  ; Exit Due to Error
  mov rdi, 1                  ; set return code
  mov rax, 60                 ; sys_exit call
  syscall
