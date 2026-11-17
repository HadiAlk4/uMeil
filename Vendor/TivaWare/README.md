# TivaWare driverlib sources

The C sources of TI's Peripheral Driver Library, from TivaWare for C Series revision 2.2.0.295. They are unchanged and are under the BSD license in `TI-BSD-EULA.txt`.

They were copied from the `driverlib/` folder of the mirror at <https://github.com/float32/tivaware>, commit `de9db41509e1cc8e13099d4f3000b176c0246d97`. The matching headers, and the `inc/` headers from the same commit, are in `uMeil/Resources/TivaWare.bundle`.

uMeil does not ship these sources. It ships the library built from them:

```sh
Vendor/TivaWare/build-driverlib.sh
```

This writes `uMeil/Resources/TivaWare.bundle/driverlib/libdriver.a`, which is checked in. The committed library was built with Homebrew's `arm-none-eabi-gcc` 16.2.0. The same compiler and sources give a byte-for-byte identical file.

`stubs/time.h` is only used when the compiler has no C library of its own, which is the case for Homebrew's `arm-none-eabi-gcc`.

## Peripheral register description (SVD)

The peripheral view reads `uMeil/Resources/TivaWare.bundle/TM4C1294NCPDT.svd`, a CMSIS-SVD file generated from TivaWare's BSD-licensed `inc/tm4c1294ncpdt.h` rather than copied from Keil's or TI's device packs:

```sh
Vendor/TivaWare/generate-svd.py
```

It takes each register's address from the header's `*_R` defines, grouped by the header's per-instance blocks, and its bit fields and named values from the `_M`, `_S` and single-bit defines that follow. GPIO registers, which TivaWare gives no fields, get one field per pin (`P0` to `P7`). FIFO data registers whose read removes an entry (`UARTn_DR`, `SSIn_DR`, `ADCn_SSFIFOn` and similar) are marked `readAction=modify`, so the view reads them only on request. The same header always gives the same file.
