# age test vectors

The official test vectors for the age format: [C2SP CCTV](https://github.com/C2SP/CCTV/tree/main/age),
`age/testdata` at commit `4448f2097b2daa812c91a26141f9f36c2096b9ca` (2026-08-29), unchanged.
`AgeTests.Passes_the_age_test_vector` runs every one of them; the ASCII armor and the hybrid
post-quantum keys are not built, so those vectors are skipped.

CCTV's README allows including the vectors without attribution; they come with the age authors'
BSD-style license all the same (`LICENSE`, from `age/internal`). To update: fetch a newer commit of
CCTV, copy `age/testdata/*` over these files, and update the commit above.
