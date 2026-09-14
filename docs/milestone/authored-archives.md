# Authored construction files

`WorldArchive` stores a versioned `.p3d` construction: grid dimensions, 1 cm cell scale, packed voxel schema, Zstandard payload and SHA-256 checksum. It is an authored build, not a checkpoint of evolving air, particles or other solver history. Opening starts a fresh experiment from the saved construction.

Save writes a sibling temporary file, checks the write and renames it over the destination. Load validates format, dimensions, compressed length and the maximum decompressed allocation before accepting bytes. An incompatible grid is rejected with the session size required to open it.

`ArchiveJob` runs compression, hashing and file access on a worker thread. Explicit saving requires one whole-volume GPU readback in Build; saving during Test uses the preserved authored snapshot. Ordinary painting continues to use regional before-images. `archive_panel.gd` owns native file dialogs, temporarily suspends editor gesture routing during a dialog and restores its prior input flags. A load that completes after an edit, reset or Build/Test transition is discarded rather than replacing the newer work.

## Current evidence

- `tests/milestone/world_archive.gd`: 13 checks for packed-byte round trip, format/size/version/checksum rejection and preserving an existing save on invalid input.
- `tests/milestone/archive_job.gd`: 5 checks for background completion, byte equality, busy-job protection and reuse after completion.
- `tests/milestone/archive_panel.gd`: 7 checks using an editor stub for authored-versus-live selection, stale-load rejection, failed-load preservation and modal input ownership.

These checks are headless and do not exercise a physical native file chooser. Actual editor attachment and GPU workflow validation are the next integration step.
