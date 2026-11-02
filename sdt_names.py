#!/usr/bin/env python3
"""TS ファイルの SDT (PID 0x11, table_id 0x42) から局名・サービス名を表示する。
TS の読み込みは自前で行い、ARIB 文字列のデコードだけ ariblib を使う。"""
import sys

from ariblib.aribstr import AribString


def sections(path, pid_want=0x11):
    buf = bytearray()
    started = False
    with open(path, "rb") as f:
        while True:
            pkt = f.read(188)
            if len(pkt) < 188:
                return
            if pkt[0] != 0x47:
                continue
            pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
            if pid != pid_want:
                continue
            afc = (pkt[3] >> 4) & 3
            i = 4
            if afc in (2, 3):
                i += 1 + pkt[4]
            if afc == 2 or i >= 188:
                continue
            payload = pkt[i:]
            if pkt[1] & 0x40:
                ptr = payload[0]
                if started:
                    buf += payload[1:1 + ptr]
                    yield from split(buf)
                buf = bytearray(payload[1 + ptr:])
                started = True
            elif started:
                buf += payload
            if started:
                yield from split(buf)


def split(buf):
    while len(buf) >= 3 and buf[0] != 0xFF:
        length = ((buf[1] & 0x0F) << 8) | buf[2]
        if len(buf) < 3 + length:
            return
        sec = bytes(buf[:3 + length])
        del buf[:3 + length]
        yield sec


def parse_sdt(sec):
    if sec[0] != 0x42:
        return None
    end = len(sec) - 4  # CRC
    i = 11
    result = {}
    while i + 5 <= end:
        sid = (sec[i] << 8) | sec[i + 1]
        dlen = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4]
        j = i + 5
        dend = j + dlen
        while j + 2 <= dend:
            tag, ln = sec[j], sec[j + 1]
            body = sec[j + 2:j + 2 + ln]
            if tag == 0x48 and len(body) >= 2:
                stype = body[0]
                pl = body[1]
                provider = body[2:2 + pl]
                nl = body[2 + pl]
                name = body[3 + pl:3 + pl + nl]
                result[sid] = (str(AribString(provider)), str(AribString(name)), stype)
            j += 2 + ln
        i = dend
    return result


def main(path):
    seen = {}
    for sec in sections(path):
        r = parse_sdt(sec)
        if r:
            seen.update(r)
            break
    if not seen:
        print("   (SDT が見つかりませんでした)")
    for sid, (provider, name, stype) in sorted(seen.items()):
        kind = {0x01: "TV", 0xC0: "データ", 0x02: "ラジオ"}.get(stype, hex(stype))
        print(f"   sid={sid:<6} {kind:<4} {name}  [{provider}]")


if __name__ == "__main__":
    main(sys.argv[1])
