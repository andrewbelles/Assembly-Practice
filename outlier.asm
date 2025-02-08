section .note.GNU-stack noalloc noexec nowrite progbits

section .rodata

  print_iter db  "Iter    : %s",  6, 0
  print_sigma db "Sigma   : %s", 10, 0
  print_mean db  "Mean    : %s", 10, 0
  print_outc db  "Outliers: %s", 10, 0

  print_newl db " ", 0
  print_test db "Test", 0

  ; test for andpd for absolute value 
  align 16
  mask dq 0x7FFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFF
  
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
  cmp rdi, 4
  jl error 

  mov rbx, [rsi + 8]              ; argv[1] input name 
  mov r13, [rsi + 16]             ; argv[2] output name
  mov rbp, [rsi + 24]             ; argv[3] (threshold) is 16 bytes offset

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

  mov r12, rax                    ; store address of heap for aggregates at r12

  ; call c library string to double to process threshold (will be placed in r12 + 8 (after fd))
  lea rdi, [rbp]
  xor rsi, rsi
  call strtod

  movsd [r12 + 16], xmm0          ; store in low memory on heap 

  ; open read file 
  mov rax, 2                      ; sys_open
  mov rdi, rbx
  xor rsi, rsi                    ; read mode  
  syscall

  ; check return value of open
  cmp rax, 0
  jl error 
  mov [r12], rax                  ; file descriptor first value in r12 

  ; open write file 
  mov rax, 2 
  mov rdi, r13 
  mov rsi, 01h | 40h | 200h
  mov rdx, 0644
  syscall

  cmp rax, 0 
  jl error 
  mov [r12 + 256], rax            ; write file descriptor

  ; full file mean, M2, count, sigma calc

  pxor xmm0, xmm0
  movsd [r12 + 48], xmm0          ; mean = 0.0
  movsd [r12 + 48], xmm0          ; M2   = 0.0
  xor rcx, rcx

  sub rsp, 8

fileLoop:

  push rcx                        ; reserve rcx through syscall

  ; read a single double value   
  mov rax, 0                      ; sys_read
  mov rdi, [r12]                  ; file descriptor
  lea rsi, [r12 + 32]             ; value buffer
  mov rdx, 8                      ; 8 bytes to read 
  syscall

  pop rcx

  cmp rax, 8
  je calcSigma 

  cmp rax, 0 
  je eofHandle

calcSigma:

  ; find standard deviation using running total
  inc rcx                         ; count++

  ; set value and curr mean
  movsd xmm0, [r12 + 32]
  movsd xmm1, [r12 + 48]
  
  subsd xmm0, xmm1                ; delta = value - mean
  movsd [r12 + 172], xmm0         ; store delta in shared/temporary heap location 

  cmp rcx, 0 
  je error

  ; get running mean from delta / count 
  cvtsi2sd xmm1, rcx             
  divsd xmm0, xmm1
  addsd xmm0, [r12 + 48]
  movsd [r12 + 48], xmm0          ; mean += delta / count  

  movsd xmm0, [r12 + 32]
  subsd xmm0, [r12 + 48]          ; delta2 = value - mean(new)

  mulsd xmm0, [r12 + 172]         ; delta * delta2 
  addsd xmm0, [r12 + 64]
  movsd [r12 + 64], xmm0          ; add to M2 

  jmp fileLoop

eofHandle: 

  mov [r12 + 80], rcx             ; store count

  ; pull M2 from heap
  movsd xmm0, [r12 + 64]
  mov rax, rcx
  dec rax
  cvtsi2sd xmm1, rax

  ; sigma = sqrt(M2 / count - 1)
  divsd xmm0, xmm1
  sqrtsd xmm0, xmm0
  movsd [r12 + 64], xmm0          ; store sigma

  ; use standard dev in xmm0 and place type to format string from and call 
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
  movsd xmm0, [r12 + 48]
  lea rdi, [r12 + 172]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  lea rdi, [print_mean]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf
  
  ; load count into string var and print
  mov rdx, [r12 + 80]
  lea rdi, [r12 + 172]
  lea rsi, [format_int] 
  xor rax, rax
  call sprintf

  ; set format and variable to print and call
  lea rdi, [print_outc]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf

  lea rdi, [format_str]
  lea rsi, [print_newl] 
  mov rax, 0 
  call printf

  mov rbx, [r12 + 80]
  imul rbx, 3
  imul rbx, 8                      ; count * 3 arrays * 8 bytes per float

  ; allocate region for arrays  
  mov rax, 9 
  xor rdi, rdi
  mov rsi, rbx
  mov rdx, 3 
  mov r10, 34
  mov r8, -1
  xor r9, r9
  syscall                    

  test rax, rax
  js error 
  
  ; r13 is the full array 
  ; r14 is the clean array 
  ; r15 is the outlier array 
  
  ; allocating arrays 
  mov r13, rax                    ; store arary addresses at r13, r14, r15 
  mov rbx, [r12 + 80]
  imul rbx, 8
  add rax, rbx
  mov r14, rax
  add rax, rbx
  mov r15, rax

  ; test print
  lea rdi, [format_str]
  lea rsi, [print_test]
  xor rax, rax 
  call printf

  mov rbx, [r12 + 80]
  mov [r12 + 180], rbx            ; store original size in aggregate heap
  mov [r12 + 196], r13            ; store original address in agg. heap 

  ; reset file pointer location 
  mov rax, 8                      ; lseek ~= fseek(fptr, 0, SEEK_SET)
  mov rdi, [r12]                  ; fd
  xor rsi, rsi
  xor rdx, rdx 
  syscall

  ; test print
  lea rdi, [format_str]
  lea rsi, [print_test]
  xor rax, rax 
  call printf  

  ; check return value of open
  cmp rax, 0
  jl error 
  mov [r12 + 8], rax              ; file descriptor first value in r12 
  
  ; test print
  lea rdi, [format_str]
  lea rsi, [print_test]
  xor rax, rax 
  call printf  

  ; init counters 
  xor r8, r8                      ; iter counter

checkEnd: 

  lea rdi, [format_str]
  lea rsi, [print_test]
  xor rax, rax 
  call printf  

  ; first iter check
  cmp r8, 0
  je outlierLoop

  cmp r10, [r12 + 160]            ; test current outlier count with previous count
  ; set end flag? 
  je handleEnd                    ; handle end of program if true 

  mov [r12 + 160], r9              ; move current into previous count if not the end

outlierLoop:

  ; counters reset per iteration
  xor r8, r8                      ; iter counter
  xor rcx, rcx                    ; value counter  
  xor r9, r9                      ; outlier counter
  xor r10, r10                    ; clean counter

  ; shift curr aggregate registers to previous aggregate registers and reset car

  ; first iter check
  cmp r8, 0 
  je threshCalc 

  ; shift values in heap
  movsd xmm0, [r12 + 96]
  movsd [r12 + 64], xmm0          ; 96 holds both M2, and sigma
  movsd xmm0, [r12 + 144]
  movsd [r12 + 48], xmm0          ; shift current mean into previous mean 

  ; shift clean array onto current array (r14 -> r13)
  ; and shift clean count onto real count
  mov r13, r14
  mov [r12 + 64], r9 

threshCalc:

  ; calculate sigma*threshold with previous sigma and place in r12 + 128
  movsd xmm0, [r12 + 16]
  mulsd xmm0, [r12 + 64]
  movsd [r12 + 128], xmm0

  cmp r8, 0 
  je readLoop 
  
readLoop: 
  
  ; push counters onto stack  
  push rcx

  ; read double to agggregate heap
  mov rax, 0                      ; sys_read
  mov rdi, [r12]              
  lea rsi, [r12 + 32]             ; double buffer
  mov rdx, 8                      ; 8 bytes to read 
  syscall

  ; revert values 
  pop rcx 

  ; place value in array r13
  ; r13[i] = [r13 + rcx * 8]
  mov rsi, 8
  imul rsi, rcx
  movsd xmm0, [r12 + 32]
  movsd [r13 + rsi], xmm0         ; iterate array r13 

  inc rcx 
  
  ; check if read the count in file 
  cmp rcx, [r12 + 80]
  jne readLoop                     ; loop till eof 

  je  arrayLoop 

arrayLoop:
  ; r8 loops to previous count (stored in rcx)
  
  ; load value from array. if abs(array - previous aggregate mean) < threshold * previous sigma add to outliers
  mov rsi, 8
  imul rsi, r8
  movsd xmm0, [r13 + rsi]

  subsd xmm0, [r12 + 48]
  movapd xmm1, [mask]
  andpd xmm0, xmm1                       ; abs(residual)

  ucomisd xmm0, [r12 + 128] 
  jg outlier
  
  ; load into clean arr
  mov rbp, 8
  imul rbp, r9
  movsd xmm0, [r13 + rsi]
  movsd [r14 + rbp], xmm0 

  inc r9                           ; iterate clean count 

  jmp calcValues
  
outlier:

  ; index outlier array and place value within it
  mov rbp, 8
  imul rbp, r10
  movsd xmm0, [r13 + rsi]
  movsd [r15 + rbp], xmm0 

  inc r10                          ; increment outlier count 

  ; push counters onto stack
  push rcx
  push r8
  push r9
  push r10

  ; sprintf call
  movsd xmm0, [r15 + rbp]
  lea rdi, [r12 + 172]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  ; revert registers  
  pop rcx
  pop r8
  pop r9
  pop r10

  lea rdi, [r12 + 172]
  xor rcx, rcx 
  
  ; count the number of characters in string to print
str_len: 

  ; compare each character to 0 
  cmp byte [rdi + rcx], 0 
  je write_out 
  inc rcx 
  jmp str_len                      ; loop if not end 

write_out:

  ; printf string to file
  mov rax, 1 
  mov rdi, [r12 + 256]             ; outliers.txt file
  lea rsi, [r12 + 172]             ; string formatted by sprintf
  mov rdx, rcx                     ; size of string  
  syscall

  jmp arrayLoop 

calcValues: ; new aggregate values are placed in a new region on the aggregate heap

  ; find standard deviation using running total
  inc rcx 

  ; set value and curr mean
  movsd xmm0, [r14 + rbp]
  movsd xmm1, [r12 + 144]
  
  subsd xmm0, xmm1                 ; delta = value - mean
  movsd [r12 + 172], xmm0          ; store delta in shared/temp memory

  cmp rcx, 0 
  je error

  ; get running mean from delta / count 
  cvtsi2sd xmm1, r10               ; load clean count as a double          
  divsd xmm0, xmm1
  addsd xmm0, [r12 + 144]
  movsd [r12 + 144], xmm0          ; mean += delta / count  

  movsd xmm0, [r14 + rbp]
  subsd xmm0, [r12 + 144]          ; delta2 = value - mean(new)

  mulsd xmm0, [r12 + 172]          ; delta * delta2 
  addsd xmm0, [r12 + 96]
  movsd [r12 + 96], xmm0           ; curr M2  

  cmp rcx, [r12 + 80]              ; check if the value counter equals total count
  je printOutput

  jmp arrayLoop

printOutput:

  ; pull final M2 and store back in same memory location 
  movsd xmm0, [r12 + 96]  
  mov rax, r9
  dec rax
  cvtsi2sd xmm1, rax
  divsd xmm0, xmm1
  sqrtsd xmm0, xmm0
  movsd [r12 + 96], xmm0          ; store sigma

  ; formatted data printed here per iteration (including final iter) 
  push rcx
  push r8
  push r9 
  push r10

; set format and variable to print and call
  lea rdi, [print_sigma]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf

  ; load mean into string var and print 
  movsd xmm0, [r12 + 144]
  lea rdi, [r12 + 172]
  lea rsi, [format_float] 
  mov rax, 1
  call sprintf

  lea rdi, [print_mean]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf
  
  ; load count into string var and print
  mov rdx, [r12 + 160]
  lea rdi, [r12 + 172]
  lea rsi, [format_int] 
  xor rax, rax
  call sprintf

  ; set format and variable to print and call
  lea rdi, [print_outc]
  lea rsi, [r12 + 172]
  mov rax, 0
  call printf

  lea rdi, [format_str]
  lea rsi, [print_newl] 
  mov rax, 0 
  call printf

  pop rcx 
  pop r8 
  pop r9
  pop r10

  add rsp, 8

  jmp checkEnd

handleEnd:

  ; load size of r13-15
  mov rbx, [r12 + 180]
  imul rbx, 8
  imul rbx, 3

  ; unmap memory
  
  ; array memory
  mov rdi, [r12 + 196]
  mov rsi, rbx
  syscall

  ; close files
  mov rax, 3
  mov rdi, [r12]
  syscall

  mov rdi, [r12 + 256]
  syscall

  ; aggregate heap
  mov rax, 11
  mov rdi, r12
  mov rsi, 512
  syscall 


  ; Handle Exit Gracefully
  xor rdi, rdi                     ; set return code
  mov rax, 60                      ; sys_exit call
  syscall

error:
  ; Exit Due to Error
  mov rdi, 1                       ; set return code
  mov rax, 60                      ; sys_exit call
  syscall
