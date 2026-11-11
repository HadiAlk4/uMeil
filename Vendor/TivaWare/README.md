# TivaWare driverlib sources

The C sources of TI's Peripheral Driver Library, from TivaWare for C Series revision 2.2.0.295. They are unchanged and are under the BSD license in `TI-BSD-EULA.txt`.

They were copied from the `driverlib/` folder of the mirror at <https://github.com/float32/tivaware>, commit `de9db41509e1cc8e13099d4f3000b176c0246d97`. The matching headers, and the `inc/` headers from the same commit, are in `uMeil/Resources/TivaWare.bundle`.

uMeil does not ship these sources. It ships the library built from them:

```sh
Vendor/TivaWare/build-driverlib.sh
```

This writes `uMeil/Resources/TivaWare.bundle/driverlib/libdriver.a`, which is checked in. The committed library was built with Homebrew's `arm-none-eabi-gcc` 16.2.0. The same compiler and sources give a byte-for-byte identical file.

`stubs/time.h` is only used when the compiler has no C library of its own, which is the case for Homebrew's `arm-none-eabi-gcc`.
