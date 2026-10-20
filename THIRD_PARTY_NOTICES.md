# Third-party notices

Hone includes or draws on the work below. The licence texts are reproduced where
the licence asks for it.

## MacDuo (MIT)

Source: https://github.com/DhananjayBhosale/MacDuo

The fold maths, the lid-angle reader and the Metal renderer in
`Sources/LidFoldKit` (`FoldMath`, `FoldEffect`, `FoldVisualAnimation`,
`LidMotionReference`, `LidStillness`, `LidSensor`, `Render/FoldShader`,
`Render/FoldRenderer`, the screen capture and overlay code) and their tests in
`Tests/LidFoldKitTests` are adapted from MacDuo's `FoldCore`, `LidSensor`,
`Shader`, `Renderer`, `DesktopCapture` and `AppModel`. Files adapted from it carry a header
comment pointing here.

    MIT License

    Copyright (c) 2026 Mac Duo contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## LidAngleSensor (Apache License 2.0)

Source: https://github.com/samhenrigold/LidAngleSensor
Licence: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)

Thanks to Sam Henri Gold for publicly documenting and demonstrating the
MacBook lid-angle sensor. The HID identifiers used by `LidSensor` (Sensor page
0x20, Orientation usage 0x8A, feature report ID 1, two-byte little-endian
degree value) follow that project's report format, as verified by MacDuo. No
source code, audio or other assets from LidAngleSensor are included in Hone.

## lid-plane by Jhey (MIT)

Source: https://github.com/jh3y/lid-plane

The Ghost effect's "resting plane" projection (a moving panel samples a desktop
plane anchored at the last resting angle) was studied from lid-plane, via
MacDuo's adaptation of it. The upstream MIT notice is retained here for that
study and adaptation.

    MIT License

    Copyright (c) 2026 Jhey

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## AudioCap (BSD 2-Clause)

Source: https://github.com/insidegui/AudioCap

Soundly's permission check and request in
`Sources/SoundlyKit/AudioCapturePermission.swift` (looking up `TCCAccessPreflight`
and `TCCAccessRequest` in the TCC framework at run time for
`kTCCServiceAudioCapture`, and reading the preflight result as 0 = granted,
1 = denied) are adapted from AudioCap's `AudioRecordingPermission.swift`. The
shape of the process-tap setup in `Sources/SoundlyKit/AppTap.swift` (a
`CATapDescription`, then a private aggregate device with the default output as
main sub-device and the tap in its tap list) follows AudioCap's `ProcessTap.swift`.
The file adapted from it carries a header comment pointing here.

    Copyright (c) 2024 Guilherme Rambo

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    - Redistributions of source code must retain the above copyright notice, this
      list of conditions and the following disclaimer. 

    - Redistributions in binary form must reproduce the above copyright notice,
      this list of conditions and the following disclaimer in the documentation
      and/or other materials provided with the distribution.

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

## FineTune (GPL-3.0) — studied, no code included

Source: https://github.com/ronitsingh10/FineTune

FineTune's tap mixer was read to learn how process taps behave in practice. No
FineTune source code is included in Hone. Two facts learnt from it shaped
Soundly's own code: tap drift compensation is left off for Bluetooth outputs
(it crackles there), and the output device's own input streams are switched off
in the IOProc's stream usage so a duplex device doesn't count as microphone use.
