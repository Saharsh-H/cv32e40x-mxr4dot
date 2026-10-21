"""Raw binary (objcopy -O binary, linked at 0x0) -> $readmemh image for
tb/mem_model.sv: one little-endian 32-bit word per line, word 0 = address 0.

usage: python3 bin2hex.py <in.bin> <out.hex>
"""
import sys

data = open(sys.argv[1], 'rb').read()
data += b'\0' * (-len(data) % 4)
with open(sys.argv[2], 'w') as f:
    for i in range(0, len(data), 4):
        f.write(f'{int.from_bytes(data[i:i + 4], "little"):08x}\n')
print(f'{sys.argv[2]}: {len(data) // 4} words ({len(data)} bytes)')
