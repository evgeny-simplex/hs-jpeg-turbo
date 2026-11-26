#ifndef SANDBOX_SETJMP_H
#define SANDBOX_SETJMP_H

typedef int jmp_buf[1];

_Noreturn void guest_longjmp(void);

#define setjmp(buffer) ((void)(buffer), 0)
#define longjmp(buffer, value) ((void)(buffer), (void)(value), guest_longjmp())

#endif
