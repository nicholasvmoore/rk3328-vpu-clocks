#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* RK3328 CRU peek/poke: ./cru <off> [value]   (off relative to CRU base) */
#define CRU_BASE 0xff440000

int main(int argc, char **argv)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    volatile unsigned int *cru = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, fd, CRU_BASE & ~0xfffUL);
    if (cru == MAP_FAILED) { perror("mmap"); return 1; }
    volatile unsigned int *reg = cru + ((CRU_BASE & 0xfff) + strtoul(argv[1], 0, 0)) / 4;
    if (argc == 3) {
        *reg = strtoul(argv[2], 0, 0);
        printf("wrote 0x%x\n", *reg);
    } else {
        printf("0x%x\n", *reg);
    }
    return 0;
}
