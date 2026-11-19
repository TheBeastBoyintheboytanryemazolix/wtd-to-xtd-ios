def tiled_outer(y, width, log_bpp):
    macro = ((y >> 5) * (width >> 5)) << (log_bpp + 7)
    micro = ((y & 6) << 2) << log_bpp
    return macro + ((micro & ~0xF) << 1) + (micro & 0xF) + ((y & 8) << (3 + log_bpp)) + ((y & 1) << 4)

def tiled_inner(x, y, log_bpp, base):
    macro = (x >> 5) << (log_bpp + 7)
    micro = (x & 7) << log_bpp
    off = base + (macro + ((micro & ~0xF) << 1) + (micro & 0xF))
    return ((off & ~0x1FF) << 3) + ((off & 0x1C0) << 2) + (off & 0x3F) + ((y & 16) << 7) + (((((y & 8) >> 2) + (x >> 3)) & 3) << 6)

def tile_blocks(src, bw, bh, bsize):
    import math
    log_bpp = bsize.bit_length()-1
    aw = (bw+31)//32*32; ah=(bh+31)//32*32
    out = bytearray(aw*ah*bsize)
    for y in range(bh):
        o = tiled_outer(y, aw, log_bpp)
        for x in range(bw):
            d = tiled_inner(x, y, log_bpp, o) 
            # inner returns byte offset already (base in bytes)
            out[d:d+bsize] = src[(y*bw+x)*bsize:(y*bw+x+1)*bsize]
    return bytes(out)

def swap16(b):
    a=bytearray(b); a[0::2],a[1::2]=b[1::2],b[0::2]; return bytes(a)
