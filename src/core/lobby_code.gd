class_name LobbyCode
extends RefCounted
## 6-char Crockford base32 lobby code (04 §2.3): no I/L/O/U, case-insensitive. The Noray relay is
## configured with this alphabet and length, so the host's OID *is* the code (deploy/noray/.env.example).

const ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const LENGTH := 6


## Typed input → canonical code, or "" if it can't be one. Crockford aliases: I/L → 1, O → 0.
static func normalize(text: String) -> String:
	var out := text.strip_edges().to_upper().replace("I", "1").replace("L", "1").replace("O", "0")
	if out.length() != LENGTH:
		return ""
	for c in out:
		if ALPHABET.find(c) < 0:
			return ""
	return out


static func encode(n: int) -> String:
	var out := ""
	for i in LENGTH:
		out = ALPHABET[n & 31] + out
		n >>= 5
	return out


static func decode(code: String) -> int:
	var n := 0
	for c in normalize(code):
		n = (n << 5) | ALPHABET.find(c)
	return n
