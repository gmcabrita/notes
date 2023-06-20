# Fast data algorithms

_From: https://jolynch.github.io/posts/use_fast_data_algorithms/_

|       Application      | Common Bad Performance Choices | Better Performance Choices |   Expected Performance Gain  |
|:----------------------:|:------------------------------:|:--------------------------:|:----------------------------:|
| Trusted data hashing   | md5, sha2, crc32               | xxhash                     | ~10x                         |
| Untrusted data hashing | md5, sha2, sha1                | blake3                     | ~10x                         |
| Fast compression       | snappy, gzip (zlib)            | lz4                        | 10x over gzip~2x over snappy |
| Good compression       | gzip (zlib)                    | zstd                       | ~2-10x                       |
| Best compression       | xz (lzma)                      | zstd -10+                  | ~2-10x                       |
