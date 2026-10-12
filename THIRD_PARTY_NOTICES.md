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
