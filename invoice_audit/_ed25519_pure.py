"""Pure-Python Ed25519 (RFC 8032) — zero native dependencies.

Used ONLY as a fallback when the `cryptography` wheel is unavailable, e.g. an
offline Windows/ARM64 guest where `pip install cryptography` has no matching
wheel and can't build from source. This is standard Ed25519, so signatures are
byte-for-byte interoperable with `cryptography`/OpenSSL: a receipt signed here
verifies there and vice-versa. Deterministic per RFC 8032.

Reference implementation (Bernstein et al. / RFC 8032 Appendix), public domain,
with extended-coordinate scalar multiplication to avoid per-bit inversions on
Windows ARM64. Correctness is pinned byte-for-byte against `cryptography` when
available and against the RFC 8032 vector otherwise (see tests).
"""
import hashlib

b = 256
q = 2 ** 255 - 19
# group order L
_L = 2 ** 252 + 27742317777372353535851937790883648493


def _H(m: bytes) -> bytes:
    return hashlib.sha512(m).digest()


def _inv(x: int) -> int:
    return pow(x, q - 2, q)


d = (-121665 * _inv(121666)) % q
_I = pow(2, (q - 1) // 4, q)


def _xrecover(y: int) -> int:
    xx = (y * y - 1) * _inv(d * y * y + 1)
    x = pow(xx, (q + 3) // 8, q)
    if (x * x - xx) % q != 0:
        x = (x * _I) % q
    if x % 2 != 0:
        x = q - x
    return x


By = (4 * _inv(5)) % q
Bx = _xrecover(By)
B = [Bx % q, By % q]


def _edwards(P, Q):
    x1, y1 = P
    x2, y2 = Q
    x3 = (x1 * y2 + x2 * y1) * _inv(1 + d * x1 * x2 * y1 * y2)
    y3 = (y1 * y2 + x1 * x2) * _inv(1 - d * x1 * x2 * y1 * y2)
    return [x3 % q, y3 % q]


def _ext_add(P, Q):
    """Add extended-coordinate points without a modular inversion."""
    x1, y1, z1, t1 = P
    x2, y2, z2, t2 = Q
    a = ((y1 - x1) * (y2 - x2)) % q
    b_ = ((y1 + x1) * (y2 + x2)) % q
    c = (2 * d * t1 * t2) % q
    d_ = (2 * z1 * z2) % q
    e = (b_ - a) % q
    f = (d_ - c) % q
    g = (d_ + c) % q
    h = (b_ + a) % q
    return [(e * f) % q, (g * h) % q, (f * g) % q, (e * h) % q]


def _ext_double(P):
    """Double an extended-coordinate point without a modular inversion."""
    x, y, z, _ = P
    a = (x * x) % q
    b_ = (y * y) % q
    c = (2 * z * z) % q
    d_ = (-a) % q
    e = ((x + y) * (x + y) - a - b_) % q
    g = (d_ + b_) % q
    f = (g - c) % q
    h = (d_ - b_) % q
    return [(e * f) % q, (g * h) % q, (f * g) % q, (e * h) % q]


def _scalarmult(P, e: int):
    """Iterative extended-coordinate scalar multiplication.

    The original reference recursion used affine addition, which performs two
    expensive modular inversions for every bit. Extended coordinates preserve
    the exact group operation and defer inversion until the final conversion.
    """
    result = [0, 1, 1, 0]
    addend = [P[0], P[1], 1, (P[0] * P[1]) % q]
    while e:
        if e & 1:
            result = _ext_add(result, addend)
        addend = _ext_double(addend)
        e //= 2
    z_inv = _inv(result[2])
    return [(result[0] * z_inv) % q, (result[1] * z_inv) % q]


def _encodeint(y: int) -> bytes:
    return y.to_bytes(b // 8, "little")


def _encodepoint(P) -> bytes:
    x, y = P
    bits = [(y >> i) & 1 for i in range(b - 1)] + [x & 1]
    return bytes(sum(bits[i * 8 + j] << j for j in range(8))
                 for i in range(b // 8))


def _bit(h: bytes, i: int) -> int:
    return (h[i // 8] >> (i % 8)) & 1


def publickey(sk: bytes) -> bytes:
    """32-byte seed -> 32-byte public key."""
    h = _H(sk)
    a = 2 ** (b - 2) + sum(2 ** i * _bit(h, i) for i in range(3, b - 2))
    A = _scalarmult(B, a)
    return _encodepoint(A)


def _Hint(m: bytes) -> int:
    return int.from_bytes(_H(m), "little")


def signature(m: bytes, sk: bytes, pk: bytes) -> bytes:
    """64-byte Ed25519 signature over m with 32-byte seed sk (pk = publickey(sk))."""
    h = _H(sk)
    a = 2 ** (b - 2) + sum(2 ** i * _bit(h, i) for i in range(3, b - 2))
    r = _Hint(h[b // 8:b // 4] + m)
    R = _scalarmult(B, r)
    S = (r + _Hint(_encodepoint(R) + pk + m) * a) % _L
    return _encodepoint(R) + _encodeint(S)


def _isoncurve(P) -> bool:
    x, y = P
    return (-x * x + y * y - 1 - d * x * x * y * y) % q == 0


def _decodepoint(s: bytes):
    y = int.from_bytes(s, "little") & ((1 << (b - 1)) - 1)
    x = _xrecover(y)
    if x & 1 != _bit(s, b - 1):
        x = q - x
    P = [x, y]
    if not _isoncurve(P):
        raise ValueError("point not on curve")
    return P


def checkvalid(s: bytes, m: bytes, pk: bytes) -> bool:
    """Verify a 64-byte signature s over m under 32-byte public key pk."""
    if len(s) != b // 4 or len(pk) != b // 8:
        return False
    try:
        R = _decodepoint(s[:b // 8])
        A = _decodepoint(pk)
    except ValueError:
        return False
    S = int.from_bytes(s[b // 8:b // 4], "little")
    h = _Hint(_encodepoint(R) + pk + m)
    return _scalarmult(B, S) == _edwards(R, _scalarmult(A, h))
