# Third-party notices

Pitbox is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). It includes the following third-party software.

## SwiftTerm 1.20.0

- Source: https://github.com/migueldeicaza/SwiftTerm (tag `v1.20.0`, revision
  `5d14406844143538cd8f8851d2d8a67c1fe443e5`, pinned exactly in `Package.swift` and `Package.resolved`)
- Used for: the terminal emulator of Pitbox's console (the `SwiftTerm` library product, linked into the `Pitbox` app)
- License: MIT

```
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Resolved but not included

`Package.resolved` also pins **swift-argument-parser 1.8.2** (https://github.com/apple/swift-argument-parser,
Apache-2.0). SwiftPM resolves it because SwiftTerm's package declares it for SwiftTerm's own command-line tool
(`termcast`). The `SwiftTerm` library Pitbox uses does not depend on it, and it is not linked into `Pitbox` or
`pitbox-command-helper`: neither binary contains any of its symbols (checked with `nm` on a debug build of the
`Pitbox` product and on a release build of the app). `swift build` or `swift test` of the whole package may compile it
as part of SwiftTerm's targets; it is not shipped in `Pitbox.app`.

## Keeping this file current

When `Package.resolved` changes, update the version, revision and license text above, and add a section for every new
package that ends up linked into `Pitbox` or `pitbox-command-helper`. New third-party dependencies need the
maintainer's agreement first ([CONTRIBUTING.md](CONTRIBUTING.md)).
