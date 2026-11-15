"""Generate/read only CI-owned Java NBT fixtures, independently of Swift code."""
import gzip
import struct

OPAQUE = bytes([0, 255, 128, 17, 31, 99, 0])

def create():
    def text(value):
        encoded = value.encode('utf-8')
        return struct.pack('>H', len(encoded)) + encoded
    def tag(kind, name, data): return bytes([kind]) + text(name) + data
    def integer(name, value): return tag(3, name, struct.pack('>i', value))
    player = tag(5, 'Health', struct.pack('>f', 20)) + integer('foodLevel', 20)
    player += tag(5, 'foodSaturationLevel', struct.pack('>f', 5))
    player += integer('XpLevel', 0) + tag(5, 'XpP', struct.pack('>f', 0)) + integer('XpTotal', 0) + b'\0'
    data = tag(8, 'LevelName', text('Native world')) + integer('GameType', 0)
    data += tag(1, 'Difficulty', bytes([2])) + tag(1, 'hardcore', b'\0') + tag(1, 'allowCommands', b'\0')
    data += tag(4, 'DayTime', struct.pack('>q', 48000)) + tag(4, 'Time', struct.pack('>q', 96000))
    data += tag(10, 'Version', tag(8, 'Name', text('1.20.1')) + b'\0')
    data += tag(7, 'mod_blob', struct.pack('>i', len(OPAQUE)) + OPAQUE) + tag(10, 'Player', player) + b'\0'
    return gzip.compress(tag(10, 'NativeFixtureRoot', tag(10, 'Data', data) + b'\0'), mtime=0)

def inspect_fixture(compressed):
    # Deliberately bounded fixture grammar, not a general player-world reader.
    raw = gzip.decompress(compressed)
    assert len(raw) < 4096
    position = 0
    def take(size):
        nonlocal position
        result = raw[position:position+size]
        assert len(result) == size
        position += size
        return result
    def unpack(fmt): return struct.unpack(fmt, take(struct.calcsize(fmt)))[0]
    def string(): return take(unpack('>H')).decode('utf-8')
    def value(kind):
        if kind in (1, 3, 4, 5): return unpack({1:'>b', 3:'>i', 4:'>q', 5:'>f'}[kind])
        if kind == 8: return string()
        if kind == 7: return take(unpack('>i'))
        assert kind == 10
        fields = {}
        while (child := unpack('>B')) != 0:
            name = string()
            assert name not in fields
            fields[name] = value(child)
        return fields
    assert unpack('>B') == 10 and string() == 'NativeFixtureRoot'
    document = value(10)
    assert position == len(raw)
    return document['Data']
