#!/bin/sh
# Builds the prebuilt driverlib that ships inside the app:
#   uMeil/Resources/TivaWare.bundle/driverlib/libdriver.a
#
# Run it again after changing the driverlib sources or the compiler flags,
# then commit the new library. Needs arm-none-eabi-gcc on the PATH, or set
# CC and AR to point at another copy.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
bundle="$here/../../uMeil/Resources/TivaWare.bundle"
output="$bundle/driverlib/libdriver.a"
objects=$(mktemp -d)
trap 'rm -rf "$objects"' EXIT

CC=${CC:-arm-none-eabi-gcc}
AR=${AR:-arm-none-eabi-ar}

for source in "$here"/driverlib/*.c; do
    # -ffile-prefix-map keeps this machine's paths out of the library.
    "$CC" -c "$source" -o "$objects/$(basename "$source" .c).o" \
        -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard \
        -std=c99 -Os -ffunction-sections -fdata-sections -ffreestanding -Wall \
        -ffile-prefix-map="$here"=. -ffile-prefix-map="$bundle"=. \
        -Dgcc -I "$bundle" -idirafter "$here/stubs"
done

# D makes the archive deterministic: no timestamps or user IDs.
rm -f "$output"
"$AR" rcsD "$output" "$objects"/*.o

echo "Built $output with $("$CC" --version | head -1)"
