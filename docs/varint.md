⏺ Decoding Varint: Step-by-Step Example

  Let's decode the number 1234567 stored as a 3-byte SQLite varint.

  The Encoding

  1234567 in binary requires 21 bits: 100101101011010000111

  Split into 7-bit chunks (from most significant to least):
  Chunk 2 (bits 14-20): 1001011 = 75
  Chunk 1 (bits 7-13):  0101101 = 45
  Chunk 0 (bits 0-6):   0000111 = 7

  Encoded bytes (high bit = 1 means "continue reading"):
  Byte 0: 0xCB = 0b1_1001011  (continuation=1, data=75)
  Byte 1: 0xAD = 0b1_0101101  (continuation=1, data=45)
  Byte 2: 0x07 = 0b0_0000111  (continuation=0, data=7)

  ---
  Decoding Step by Step

  Initial state:
  result (64 bits): 0000000000000000000000000000000000000000000000000000000000000000

  ---
  Step 1: Read byte 0xCB

  cur_byte = 0xCB = 0b11001011

  Mask off high bit:
  cur_byte & 0x7F = 0b11001011
                 & 0b01111111
                 = 0b01001011 = 75

  Shift result left by 7 (result is 0, so still 0):
  result << 7 = 0

  OR them together:
  result = 0 | 75 = 75

  result (64 bits): 0000000000000000000000000000000000000000000000000000000001001011
                                                                      ^^^^^^^
                                                                      75 sits here

  High bit of 0xCB is 1, so continue reading.

  ---
  Step 2: Read byte 0xAD

  cur_byte = 0xAD = 0b10101101

  Mask off high bit:
  cur_byte & 0x7F = 0b00101101 = 45

  Shift result left by 7 (this is the key operation):
  result << 7:

  BEFORE: 0000000000000000000000000000000000000000000000000000000001001011
                                                                   |||||||
  AFTER:  0000000000000000000000000000000000000000000000000010010110000000
                                                            |||||||^^^^^^^
                                                            75     7 zeros (empty space)

  result << 7 = 75 * 128 = 9600

  OR in the new 7 bits:
  result = 9600 | 45

          0000000000000000000000000000000000000000000000000010010110000000  (9600)
        | 0000000000000000000000000000000000000000000000000000000000101101  (45)
        = 0000000000000000000000000000000000000000000000000010010110101101  (9645)
                                                            |||||||^^^^^^^
                                                            75     45

  High bit of 0xAD is 1, so continue reading.

  ---
  Step 3: Read byte 0x07

  cur_byte = 0x07 = 0b00000111

  Mask off high bit:
  cur_byte & 0x7F = 0b00000111 = 7

  Shift result left by 7:

  BEFORE: 0000000000000000000000000000000000000000000000000010010110101101
                                                           ||||||||||||||
  AFTER:  0000000000000000000000000000000000000000000100101101011010000000
                                                      ||||||||||||||^^^^^^^
                                                      9645          7 zeros

  result << 7 = 9645 * 128 = 1234560

  OR in the new 7 bits:
  result = 1234560 | 7

          0000000000000000000000000000000000000000000100101101011010000000  (1234560)
        | 0000000000000000000000000000000000000000000000000000000000000111  (7)
        = 0000000000000000000000000000000000000000000100101101011010000111  (1234567)
                                                      |||||||||||||||||||||
                                                      21 bits of data

  High bit of 0x07 is 0, so stop reading.

  ---
  Final Result

  result = 1234567
  bytes consumed = 3

  The 64-bit integer accumulated the value 7 bits at a time. Each left shift moved existing bits "up" to make room for the next chunk. The OR operation placed the new bits into that empty space.
