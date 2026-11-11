// Blinky for the EK-TM4C1294XL LaunchPad.
//
// Blinks user LED D1 (pin PN1) once a second. The chip runs from its
// internal 16 MHz oscillator, which is the default after reset.

#include <stdbool.h>
#include <stdint.h>

#include "inc/hw_memmap.h"
#include "driverlib/gpio.h"
#include "driverlib/sysctl.h"

#define SYSTEM_CLOCK_HZ 16000000u

// SysCtlDelay() spends three clock cycles on each loop.
#define HALF_SECOND (SYSTEM_CLOCK_HZ / 3 / 2)

int main(void)
{
    // Turn on GPIO port N and wait until it is ready to use.
    SysCtlPeripheralEnable(SYSCTL_PERIPH_GPION);
    while (!SysCtlPeripheralReady(SYSCTL_PERIPH_GPION)) {
    }

    GPIOPinTypeGPIOOutput(GPIO_PORTN_BASE, GPIO_PIN_1);

    for (;;) {
        GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, GPIO_PIN_1);
        SysCtlDelay(HALF_SECOND);

        GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);
        SysCtlDelay(HALF_SECOND);
    }
}
