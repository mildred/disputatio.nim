import std/json
import canonicaljson
import libp2p/multihash

proc compute_payload*(input: JsonNode): string =
  result = canonify(input)

proc compute_hash*(input: JsonNode): string =
  # = base58btc(CIDv0)
  # = base58btc(hash & length & hash)
  # = base58btc([0x12] & [0x20] & hash)
  result = MultiHash.digest("sha2-256", cast[seq[byte]](compute_payload(input))).get().base58()

