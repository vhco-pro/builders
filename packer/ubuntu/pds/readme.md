# PDS package inputs

`repository-key.asc` is the public signing key served by
[PDS's APT repository](https://michielvha.github.io/PDS/pds-repo.gpg), inspected on 2026-11-05.
Its primary fingerprint is `37C7D029C0FE4DB0E66E5F72AFA1101D94CBF301`.
The installer checks that the supplied key contains exactly that primary key before configuring APT.
No private key belongs in this directory.

The default `pds_version` pins published PDS 0.20.0, which contains the image recipe's selected
helpers. The normal build installs that exact version from the signed APT repository. Builds fail
if selected functions are missing; there is no fallback to an unpinned script or another version.

To test the dependent package before release, prepare a new directory outside Git containing this
public key and the candidate package named `candidate.deb`. Set `pds_input_directory` to its absolute
path, `pds_version` to the package's exact Debian version, and `pds_candidate_sha256` to its checksum.
Both package metadata and installed metadata must match. The image records this route as `candidate`
in `/var/lib/builders/pds.json`; it does not count as signed-release validation. The signed APT
source remains configured for later deployed updates.

The ordinary route leaves `pds_candidate_sha256` empty and installs `pds=<pds_version>` through the
signed repository. An unexpected `candidate.deb` without a checksum is rejected.
