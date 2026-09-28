# FFmpeg runtime notice

VitaLab invokes FFmpeg as a separate command-line program for Windows capture
and media inspection. The pinned runtime is built by BtbN from FFmpeg source
and is licensed under the GNU Lesser General Public License version 3 or later.

The runtime package, its `LICENSE.txt`, the exact matching source archive, and
this manifest must be included together in any VitaLab installer or binary
distribution. `manifest.json` records the source commit, download locations,
and SHA-256 identities used by the host preflight.

VitaLab must not package an FFmpeg build configured with `--enable-gpl` or
`--enable-nonfree`.

- FFmpeg: https://ffmpeg.org/
- FFmpeg source: https://github.com/FFmpeg/FFmpeg
- Windows build provider: https://github.com/BtbN/FFmpeg-Builds
- LGPL v3: https://www.gnu.org/licenses/lgpl-3.0.html
