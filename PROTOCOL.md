# Tailbolt wire protocol v2

Plain TCP on port **48484** over the tailnet. Tailscale (WireGuard) provides encryption and peer
authentication for everything that goes through the tunnel; the receiver identifies the sender by
source IP via `tailscale status`. Data connections may additionally run **directly across the LAN**
with their own end-to-end encryption (see *LAN fast path*).

v2 is a superset of v1: every new field is optional and only used when the other side announced the
matching capability in `hello.caps`.

## Framing

Every message is a frame: `uint32 big-endian length` + UTF-8 JSON object. The only exception is the
payload that directly follows a `chunk` message (exactly `n` raw bytes).

## Control connection

```
C → S  {"t":"hello","v":2,"name":"Saras Mac mini","os":"macOS","app":"2.0","caps":["lz4","lan"]}
S → C  {"t":"hello","v":2,"name":"MacBook Pro","os":"macOS","app":"2.0","caps":["lz4","lan"]}
```

A probe stops here (`{"t":"bye"}` + close). To send, the client continues:

```
C → S  {"t":"offer","id":"<uuid>","total":123,"chunk":16777216,
        "items":[{"p":"Folder","s":0,"d":true,"m":1730000000.0},
                 {"p":"Folder/a.bin","s":123,"d":false,"m":1730000000.0,"x":true},
                 {"p":"Folder/link","s":0,"d":false,"l":"a.bin"}]}
```

Item fields: `p` relative path with `/` (no leading `/`, no `.`/`..`/empty components),
`s` size, `d` directory, `m` mtime (unix seconds, optional), `x` executable (optional),
`l` symlink target (optional; item has `s == 0`, nothing may be nested below it).

The receiver asks its user (may take minutes; it gives up after 5 min), then answers:

```
S → C  {"t":"accept","streams":4,
        "key":"<base64 32 random bytes>",          // only if both announced "lan"
        "lan":["192.168.3.77","192.168.64.1"]}      // receiver's local IPv4 addresses
   or  {"t":"decline","reason":"…"}
```

After `accept` the control connection stays open. When all bytes are on disk and moved into place:

```
S → C  {"t":"done"}                       or   {"t":"error","reason":"…"}
```

Closing the control connection from either side cancels the transfer.

## Data connections (tailnet)

The client opens up to `streams` additional connections through the tailnet:

```
C → S  {"t":"data","id":"<uuid>"}
C → S  {"t":"chunk","f":<item index>,"o":<offset>,"n":<bytes on the wire>}  + n raw bytes
C → S  {"t":"chunk","f":..,"o":..,"n":<compressed bytes>,"c":"lz4","u":<uncompressed length>} + n bytes
S → C  {"t":"ack","f":<item index>,"o":<offset>}                  (after the bytes are written)
…
C → S  {"t":"bye"}
```

Chunks: every non-empty regular file split into `chunk`-sized pieces (last piece shorter). Clients
pull chunks from a shared queue, pipeline them without waiting for acks, and re-send every unacked
chunk of a broken connection on a new one. The receiver ignores duplicate chunks (still acks them),
and only accepts tailnet data connections from the same IP as the control connection.

### Compression

Only when the receiver listed `"lz4"`. The sender compresses a chunk with **LZ4 raw block format**
(`compression_encode_buffer(COMPRESSION_LZ4_RAW)` / `LZ4_compress_default`) when a 256 KB sample
shrinks below 90 % and the whole chunk below 97 %; otherwise the chunk is sent raw. `u` is the
original length; the receiver decompresses into exactly `u` bytes and writes them at `o`.
Files with known-compressed extensions (zip, mp4, jpg, …) skip the sample.

## LAN fast path

Only when both sides listed `"lan"` and the accept carried a `key`. The sender picks LAN addresses
that are on one of its own subnets (the endpoint Tailscale reports as `CurAddr` first, then the
receiver's advertised list, never its own addresses) and opens extra data connections **to the same
port** directly:

```
C → S  {"t":"data","id":"<uuid>","ci":<connection index>}      (plaintext envelope)
       … everything after this, both directions, is a sequence of sealed records …
C → S  {"t":"lan-hello","nonce":"<random>"}                     (sealed)
S → C  {"t":"lan-ok","nonce":"<same>"}                          (sealed)
C → S  chunk … / S → C ack …                                    (sealed, as on the tailnet)
```

Record = `uint32 big-endian length` + AES-256-GCM ciphertext + 16-byte tag, ≤ 1 MiB plaintext each.
The decrypted byte stream is exactly the same framing as a tailnet data connection. Keys and nonces:

- `K_ci = HKDF-SHA256(ikm = key, salt = transfer id, info = "tailbolt-lan-v2/<ci>", 32 bytes)` —
  one key per connection; the receiver rejects a reused `ci`.
- nonce (96 bit) = `uint32 direction` (1 = sender→receiver, 2 = receiver→sender) + `uint64 counter`
  starting at 0 per direction and connection; AAD = transfer id (UTF-8).
- Handshake first: the sender streams no payload until `lan-ok` echoes its nonce, so data never flows to
  a host that doesn't hold the session key (no reflection to a spoofed LAN address). The receiver gives
  the sealed hello 3 s, keeps at most 8 unauthenticated knocks pending, holds `ci` only tentatively until
  the hello authenticates, and allocates buffers only afterwards.
- The fast path is optional: a sender that cannot reach any LAN address (AP isolation, denied
  "Lokales Netzwerk" permission) simply finishes through the tailnet streams. Once a LAN stream has
  acked a chunk, tailnet streams only take chunks while more than 2 per proven LAN stream remain.
