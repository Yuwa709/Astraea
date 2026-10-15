# Third-party licences

PopNotch itself is MIT licensed (see `LICENSE`). It redistributes, in binary
form, the components listed below. Their licence terms follow verbatim.

---

## mediaremote-adapter

- **Upstream:** https://github.com/ungive/mediaremote-adapter
- **Licence:** BSD 3-Clause
- **Copyright:** Copyright (c) 2025, Jonas van den Berg and contributors

### What PopNotch ships, and where it came from

All three artifacts originate from `ungive/mediaremote-adapter`. They were
obtained as the built products of **`ungive/media-control` v0.7.6**
(tag `v0.7.6`, revision `815bcb5fb514da137e75ca5b866ffb2fb72f224e`), which
vendors `mediaremote-adapter` as a git submodule and builds it via CMake.
Homebrew's `media-control` formula declares `license "BSD-3-Clause"`, and the
`media-control` README states the same terms and copyright. At revision
`815bcb5` the `media-control` repository carries no `LICENSE` file of its own;
the licence text below is the one shipped in the `mediaremote-adapter`
submodule, which is the origin of every file PopNotch redistributes.

| Shipped at (in `PopNotch.app`) | In this repo | Upstream origin |
|---|---|---|
| `Contents/Frameworks/MediaRemoteAdapter.framework` | `vendor/MediaRemoteAdapter.framework` | `ungive/mediaremote-adapter`, compiled from `src/` |
| `Contents/MacOS/MediaRemoteAdapterTestClient` | `vendor/MediaRemoteAdapterTestClient` | `ungive/mediaremote-adapter`, compiled from `src/test` |
| `Contents/Resources/mediaremote-adapter.pl` | `vendor/mediaremote-adapter.pl` | `ungive/mediaremote-adapter`, `bin/mediaremote-adapter.pl`, byte-for-byte |

`media-control`'s own `bin/media-control` — a Perl wrapper that only parses
command names and re-executes `mediaremote-adapter.pl` — is deliberately **not**
redistributed. PopNotch invokes the adapter script directly.

### Modifications

The Perl script is unmodified and retains its inline copyright header. The two
Mach-O objects are unmodified in content; at release time `scripts/release.sh`
rewrites the framework's `LC_ID_DYLIB` install name (which upstream's build
hardcodes to a Homebrew prefix) and re-signs both objects with PopNotch's own
ad-hoc signature, as macOS bundle embedding requires.

### Licence text

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
