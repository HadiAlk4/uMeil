#!/usr/bin/env python3
"""Writes a CMSIS-SVD description of the TM4C1294NCPDT from TivaWare's
BSD-licensed register header, tm4c1294ncpdt.h.

The header lists every register's address, grouped by peripheral instance
("// UART registers (UART0)"), followed by the bit fields of each register
("// The following are defines for the bit fields in the UART_O_CTL
register."). This script turns that into the SVD file uMeil's peripheral
view reads, so uMeil does not have to ship Keil's or TI's SVD.

Usage:
    Vendor/TivaWare/generate-svd.py

Writes uMeil/Resources/TivaWare.bundle/TM4C1294NCPDT.svd. Running it again on
the same header gives the same file.
"""

import re
import sys
from collections import OrderedDict
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "uMeil/Resources/TivaWare.bundle/inc/tm4c1294ncpdt.h"
OUTPUT = ROOT / "uMeil/Resources/TivaWare.bundle/TM4C1294NCPDT.svd"

# Bit-field groups written as GROUP_O_REG belong to every instance of a kind
# of peripheral; this names the kind as the header's block comments do.
GROUP_KINDS = {
    "WDT": "Watchdog Timer",
    "SSI": "SSI",
    "UART": "UART",
    "I2C": "I2C",
    "PWM": "PWM",
    "QEI": "QEI",
    "TIMER": "Timer",
    "ADC": "ADC",
    "COMP": "Comparator",
    "CAN": "CAN",
    "USB": "Univeral Serial Bus",
    "EPI": "External Peripheral Interface",
    "CCM": "EC",
    "GPIO": "GPIO",
}

# GPIO registers that hold one bit per pin. TivaWare names no fields for
# them, so each gets eight one-bit fields, P0 to P7.
GPIO_PIN_REGISTERS = {
    "DATA", "DIR", "IS", "IBE", "IEV", "IM", "RIS", "MIS", "ICR", "AFSEL",
    "DR2R", "DR4R", "DR8R", "DR12R", "ODR", "PUR", "PDR", "SLR", "DEN", "CR",
    "AMSEL", "ADCCTL", "DMACTL", "WAKEPEN", "WAKELVL", "WAKESTAT",
}
GPIO_PIN_FIELDS = [(f"P{n}", n, 1, f"Pin {n}", []) for n in range(8)]

# Registers whose read changes the chip: reading a FIFO's data register
# takes the next entry out of it. The peripheral view only reads these when
# asked to.
SIDE_EFFECT_READS = re.compile(
    r"^(UART\d+_DR|SSI\d+_DR|ADC\d+_SSFIFO\d|EPI\d+_READFIFO\d*|USB\d+_FIFO\d+|"
    r"CAN\d+_IF\dDA\d|CAN\d+_IF\dDB\d|EMAC\d+_RXFIFO.*|I2C\d+_MDR|I2C\d+_SDR|"
    r"I2C\d+_FIFODATA)$"
)

REGISTER = re.compile(r"^#define\s+(\w+)_R\s+\(\*\(\(volatile uint32_t \*\)(0x[0-9A-Fa-f]+)\)\)")
BLOCK = re.compile(r"^// (.+) registers \((.+)\)\s*$")
FIELDS = re.compile(r"^// The following are defines for the bit fields in the (\w+)")
DEFINE = re.compile(r"^#define\s+(\w+)\s+(0x[0-9A-Fa-f]+|\d+)\s*(?://\s*(.*))?$")


class Peripheral:
    def __init__(self, kind, name):
        self.kind = kind
        self.name = name
        self.registers = OrderedDict()  # full name -> address
        self.prefix = ""

    def short(self, full):
        return full[len(self.prefix):]


def read_header():
    # Long names push a define's value onto the next line after a backslash.
    text = re.sub(r"\s*\\\n\s*", " ", HEADER.read_text(encoding="latin-1"))
    lines = text.splitlines()
    peripherals = []
    field_sections = []  # (section name, [(name, value, comment)])
    current = None
    section = None
    for line in lines:
        block = BLOCK.match(line)
        if block:
            current = Peripheral(block.group(1).strip(), block.group(2).strip())
            peripherals.append(current)
            section = None
            continue
        fields = FIELDS.match(line)
        if fields:
            section = (fields.group(1), [])
            field_sections.append(section)
            current = None
            continue
        register = REGISTER.match(line)
        if register and current is not None:
            current.registers[register.group(1)] = int(register.group(2), 16)
            continue
        define = DEFINE.match(line)
        if define and section is not None:
            value = int(define.group(2), 0)
            section[1].append((define.group(1), value, (define.group(3) or "").strip()))
    peripherals = [p for p in peripherals if p.registers]
    for peripheral in peripherals:
        names = list(peripheral.registers)
        prefix = names[0]
        for name in names[1:]:
            while not name.startswith(prefix):
                prefix = prefix[:-1]
        # Cut back to a whole word: "GPIO_PORTN_D" becomes "GPIO_PORTN_".
        peripheral.prefix = prefix[: prefix.rfind("_") + 1] if "_" in prefix else ""
    return peripherals, field_sections


def svd_name(peripheral):
    """GPIO_PORTN_ becomes GPIO_PORTN; WATCHDOG0_ becomes WATCHDOG0."""
    return peripheral.prefix.rstrip("_") or peripheral.name.replace(" ", "_")


def parse_fields(prefix, defines):
    """Turns a section's defines into fields: (name, lsb, width, description,
    [(enum name, value, description)])."""
    fields = OrderedDict()
    for name, value, comment in defines:
        short = name[len(prefix):] if name.startswith(prefix) else None
        if not short:
            continue
        if short.endswith("_S"):
            continue
        if short.endswith("_M") or short == "M":
            field = short[:-2] if short.endswith("_M") else ""
            if value == 0:
                continue
            fields[field or "VALUE"] = [value, comment, []]
            continue
        owner = next((f for f in fields if short.startswith(f + "_") and bin(fields[f][0]).count("1") > 1), None)
        if owner is not None:
            mask = fields[owner][0]
            lsb = (mask & -mask).bit_length() - 1
            if value & ~mask == 0:
                fields[owner][2].append((short[len(owner) + 1:], (value & mask) >> lsb, comment))
            continue
        if value == 0:
            continue
        lsb = (value & -value).bit_length() - 1
        contiguous = ((value >> lsb) & ((value >> lsb) + 1)) == 0
        if contiguous and short not in fields:
            fields[short] = [value, comment, []]
    result = []
    for name, (mask, comment, enums) in fields.items():
        lsb = (mask & -mask).bit_length() - 1
        width = bin(mask).count("1")
        if ((mask >> lsb) & ((mask >> lsb) + 1)) != 0:
            continue  # Not one run of bits.
        result.append((name, lsb, width, comment, enums))
    return result


def attach_fields(peripherals, field_sections):
    """Returns {(peripheral svd name, register short name): fields}."""
    by_kind = {}
    for peripheral in peripherals:
        by_kind.setdefault(peripheral.kind, []).append(peripheral)
    by_full = {}
    for peripheral in peripherals:
        for full in peripheral.registers:
            by_full[full] = peripheral

    attached = {}
    for section, defines in field_sections:
        if "_O_" in section:
            group, register = section.split("_O_", 1)
            kind = GROUP_KINDS.get(group)
            if kind is None:
                continue
            fields = parse_fields(f"{group}_{register}_", defines)
            if not fields:
                continue
            for peripheral in by_kind.get(kind, []):
                for full in peripheral.registers:
                    if peripheral.short(full) == register:
                        attached[(svd_name(peripheral), register)] = fields
        else:
            peripheral = by_full.get(section)
            if peripheral is None:
                continue
            fields = parse_fields(section + "_", defines)
            if fields:
                attached[(svd_name(peripheral), peripheral.short(section))] = fields
    return attached


def register_xml(peripheral, full, address, base, fields):
    short = peripheral.short(full)
    out = ["        <register>",
           f"          <name>{escape(short)}</name>",
           f"          <addressOffset>0x{address - base:X}</addressOffset>"]
    if SIDE_EFFECT_READS.match(full):
        out.append("          <readAction>modify</readAction>")
    if fields:
        out.append("          <fields>")
        for name, lsb, width, comment, enums in fields:
            out.append("            <field>")
            out.append(f"              <name>{escape(name)}</name>")
            if comment:
                out.append(f"              <description>{escape(comment)}</description>")
            out.append(f"              <bitOffset>{lsb}</bitOffset>")
            out.append(f"              <bitWidth>{width}</bitWidth>")
            if enums:
                out.append("              <enumeratedValues>")
                for enum_name, value, enum_comment in enums:
                    out.append("                <enumeratedValue>")
                    out.append(f"                  <name>{escape(enum_name)}</name>")
                    if enum_comment:
                        out.append(f"                  <description>{escape(enum_comment)}</description>")
                    out.append(f"                  <value>{value}</value>")
                    out.append("                </enumeratedValue>")
                out.append("              </enumeratedValues>")
            out.append("            </field>")
        out.append("          </fields>")
    out.append("        </register>")
    return out


def main():
    peripherals, field_sections = read_header()
    attached = attach_fields(peripherals, field_sections)

    out = ['<?xml version="1.0" encoding="utf-8"?>',
           "<!-- Generated by Vendor/TivaWare/generate-svd.py from TivaWare's tm4c1294ncpdt.h",
           "     (TivaWare for C Series 2.2.0.295, BSD license in TI-BSD-EULA.txt). Do not edit. -->",
           '<device schemaVersion="1.1" xmlns:xs="http://www.w3.org/2001/XMLSchema-instance">',
           "  <vendor>Texas Instruments</vendor>",
           "  <name>TM4C1294NCPDT</name>",
           "  <version>2.2.0.295</version>",
           "  <description>TM4C1294NCPDT Cortex-M4F microcontroller</description>",
           "  <cpu>",
           "    <name>CM4</name>",
           "    <revision>r0p1</revision>",
           "    <endian>little</endian>",
           "    <mpuPresent>true</mpuPresent>",
           "    <fpuPresent>true</fpuPresent>",
           "    <nvicPrioBits>3</nvicPrioBits>",
           "    <vendorSystickConfig>false</vendorSystickConfig>",
           "  </cpu>",
           "  <addressUnitBits>8</addressUnitBits>",
           "  <width>32</width>",
           "  <size>32</size>",
           "  <access>read-write</access>",
           "  <peripherals>"]

    for peripheral in peripherals:
        name = svd_name(peripheral)
        base = min(peripheral.registers.values()) & ~0xFFF
        out.append("    <peripheral>")
        out.append(f"      <name>{escape(name)}</name>")
        out.append(f"      <description>{escape(peripheral.kind)} ({escape(peripheral.name)})</description>")
        out.append(f"      <groupName>{escape(peripheral.kind)}</groupName>")
        out.append(f"      <baseAddress>0x{base:08X}</baseAddress>")
        out.append("      <registers>")
        for full, address in peripheral.registers.items():
            fields = attached.get((name, peripheral.short(full)), [])
            if peripheral.kind == "GPIO" and peripheral.short(full) in GPIO_PIN_REGISTERS:
                fields = GPIO_PIN_FIELDS
            out.extend(register_xml(peripheral, full, address, base, fields))
        out.append("      </registers>")
        out.append("    </peripheral>")

    out.append("  </peripherals>")
    out.append("</device>")
    OUTPUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    registers = sum(len(p.registers) for p in peripherals)
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(peripherals)} peripherals, "
          f"{registers} registers, {len(attached)} with bit fields", file=sys.stderr)


if __name__ == "__main__":
    main()
