/* Fallback <time.h> for compilers that come without a C library, such as
   Homebrew's arm-none-eabi-gcc. driverlib's hibernate.c only needs struct tm.

   build-driverlib.sh adds this folder with -idirafter, so a toolchain's own
   <time.h> is used instead whenever it has one. The layout below matches
   newlib, the C library of the Arm GNU Toolchain. */

#ifndef UMEIL_STUB_TIME_H
#define UMEIL_STUB_TIME_H

struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
};

#endif
