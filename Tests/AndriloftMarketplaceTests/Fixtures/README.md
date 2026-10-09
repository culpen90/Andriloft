# Marketplace APK fixtures

`HelloAndroid.apk` is the project's compiled Java example. `HighlyCompressedAndroid.apk` repacks that example with a 1 MiB zero-filled Unity-style asset, compressed by over 1,000 times. It exercises the complete marketplace checksum, APK/DEX validation, and save path without distributing a third-party game. These fixtures are parsed, never executed by marketplace tests; APK signing certificates are not verified.

Regenerate the high-compression fixture from the repository root using Python's standard library:

```python
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

fixtures = Path("Tests/AndriloftMarketplaceTests/Fixtures")
with ZipFile(fixtures / "HelloAndroid.apk") as source, ZipFile(
    fixtures / "HighlyCompressedAndroid.apk", "w",
    compression=ZIP_DEFLATED, compresslevel=9,
) as destination:
    for entry in source.infolist():
        destination.writestr(entry.filename, source.read(entry.filename))
    destination.writestr("assets/bin/Data/zero-filled.assets", bytes(1024 * 1024))
```

`UnicodeIdentifiersAndroid.apk` repacks the example with a synthetic ordinary DEX 035 containing two unused public classes. Their names end with U+0390 and U+1FD3: distinct UTF-16 identifiers that compare equal under Swift's Unicode canonical equivalence. This exercises the complete marketplace validation and save path for the class-identity bug reproduced in Subway Surfers. The synthetic DEX includes its section map, SHA-1 signature, and Adler-32 checksum. The APK is a parser fixture; repacking does not preserve the original APK signature.

Regenerate the Unicode fixture from the repository root with this Python standard-library recipe. Fixed ZIP timestamps and metadata make its output deterministic:

```python
from hashlib import sha1
from pathlib import Path
from struct import pack, pack_into
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
from zlib import adler32

fixtures = Path('Tests/AndriloftMarketplaceTests/Fixtures')
# DEX identifiers retain distinct UTF-16 units even when Swift Strings compare equal.
names = ['Ldemo/\u0390;', 'Ldemo/\u1fd3;', 'Ljava/lang/Object;']
strings_at, types_at, classes_at, data_at = 112, 124, 136, 200
dex = bytearray(data_at)
dex[:8] = b'dex\n035\0'

def u32(offset, value):
    pack_into('<I', dex, offset, value)

def uleb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return result

for index, name in enumerate(names):
    u32(strings_at + index * 4, len(dex))
    dex += uleb(len(name.encode('utf-16-le')) // 2) + name.encode('utf-8') + b'\0'
    u32(types_at + index * 4, index)
for index in range(2):
    offset = classes_at + index * 32
    u32(offset, index)                 # class_idx
    u32(offset + 4, 1)                 # public
    u32(offset + 8, 2)                 # superclass_idx: java.lang.Object
    u32(offset + 16, 0xffffffff)       # no source_file_idx
while len(dex) % 4:
    dex.append(0)
map_at = len(dex)
items = [(0x0000, 1, 0), (0x0001, 3, strings_at), (0x0002, 3, types_at),
         (0x0006, 2, classes_at), (0x2002, 3, data_at), (0x1000, 1, map_at)]
dex += pack('<I', len(items))
for kind, count, offset in items:
    dex += pack('<HHII', kind, 0, count, offset)
for offset, value in [(32, len(dex)), (36, 112), (40, 0x12345678), (52, map_at),
                      (56, 3), (60, strings_at), (64, 3), (68, types_at),
                      (96, 2), (100, classes_at), (104, len(dex) - data_at),
                      (108, data_at)]:
    u32(offset, value)
dex[12:32] = sha1(dex[32:]).digest()
u32(8, adler32(dex[12:]) & 0xffffffff)

with ZipFile(fixtures / 'HelloAndroid.apk') as source, ZipFile(
    fixtures / 'UnicodeIdentifiersAndroid.apk', 'w', compression=ZIP_DEFLATED,
    compresslevel=9,
) as destination:
    def add(name, content):
        entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        entry.compress_type = ZIP_DEFLATED
        entry.external_attr = 0o100644 << 16
        destination.writestr(entry, content, compresslevel=9)
    for entry in source.infolist():
        add(entry.filename, source.read(entry.filename))
    add('classes2.dex', dex)
```
