TivaWare for C Series, revision 2.2.0.295, trimmed for uMeil.

Copyright (c) Texas Instruments Incorporated. Distributed under the BSD
license in TI-BSD-EULA.txt.

What is here:
  inc/                    Register headers (hw_*.h) and tm4c1294ncpdt.h.
                          Headers for other chips are left out.
  TM4C1294NCPDT.svd       CMSIS-SVD register description for the peripheral
                          view, generated from tm4c1294ncpdt.h by
                          Vendor/TivaWare/generate-svd.py.
  driverlib/*.h           The Peripheral Driver Library headers, unchanged.
  driverlib/libdriver.a   The Peripheral Driver Library, built by uMeil for
                          the Cortex-M4 with the hardware FPU
                          (-mfpu=fpv4-sp-d16 -mfloat-abi=hard).

The library's sources and build script are in Vendor/TivaWare in the uMeil
repository.
