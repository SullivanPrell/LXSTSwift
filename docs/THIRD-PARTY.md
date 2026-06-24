# Third-Party Notices

LXSTSwift is a Swift port of, and a derivative work of, the original LXST:

> **LXST** — Copyright (c) Mark Qvist — Reticulum License
> https://github.com/markqvist/LXST

LXSTSwift adopts the same **Reticulum License** (see [`LICENSE`](../LICENSE)) for
its own source. It additionally **redistributes prebuilt binaries** of two audio
codec libraries, under their own licenses, reproduced below.

---

> **Pinned versions:** codec2 **1.2.0**, opus **v1.6.1**. Both are built by the
> *Build binaries* workflow and distributed as Release assets (not committed to
> git), consumed via checksummed `binaryTarget(url:)`.

## codec2 — GNU LGPL v2.1

`Resources/codec2.xcframework` is a prebuilt static library of **codec2**:

> codec2 — Copyright (C) David Rowe and contributors
> https://github.com/drowe67/codec2

codec2 is licensed under the **GNU Lesser General Public License, version 2.1**.
The full text of the LGPL v2.1 is available at
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt> and in the `COPYING`
file of the codec2 source distribution.

### Your LGPL right to relink

The LGPL guarantees you the right to use LXSTSwift with a **modified version of
codec2**. Because the codec2 source is publicly available and the xcframework in
this repository can be regenerated from it, that right is fully exercisable:

1. Obtain and modify the codec2 source from <https://github.com/drowe67/codec2>.
2. Rebuild `codec2.xcframework` — see [CONTRIBUTING.md](../CONTRIBUTING.md#rebuilding-the-codec-binaries).
3. Replace `Resources/codec2.xcframework` and rebuild LXSTSwift (and any app
   embedding it).

LXSTSwift links codec2 only through codec2's public C API; no codec2 source is
modified or statically embedded beyond the prebuilt library object.

---

## opus — BSD 3-Clause

`Resources/opus.xcframework` is a prebuilt static library of **libopus**:

```
Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo, Mozilla, Amazon

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The Opus codec is also subject to royalty-free patent grants from its
contributors; see the IPR statements referenced in the opus source
`LICENSE_PLEASE_READ.txt`.

---

## AVFoundation / Accelerate

LXSTSwift uses Apple's **AVFoundation** (AVAudioEngine / AVAudioConverter) and
system frameworks for audio I/O and Opus resampling. These ship with the OS and
are not redistributed by this project.
