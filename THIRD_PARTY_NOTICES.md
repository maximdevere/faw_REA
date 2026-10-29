# Third-party software

This project supplies Docker packaging and integration, not ownership of the
included analysis engines. Each component keeps its upstream license and notices.

| Component | License / primary source |
| --- | --- |
| REA | MIT; https://github.com/morluto/rea |
| Node.js | MIT and bundled notices; https://nodejs.org/ |
| Ghidra | Apache-2.0 and bundled third-party notices; https://github.com/NationalSecurityAgency/ghidra |
| JADX headless MCP | Refer to engine JAR and upstream; https://github.com/1013503897/jadx-headless-mcp |
| Apktool | Apache-2.0 and dependencies; https://github.com/iBotPeaches/Apktool |
| OpenJDK and OS packages | Distribution-provided copyright/license files in /usr/share/doc |
| Optional Appium ApiDemos test APK | Apache-2.0; https://github.com/appium/android-apidemos |

The optional test APK is downloaded separately and verified; it is not installed
on a device and is not bundled in the runtime image. No IDA installer or license
is included. The license below applies only to the packaging source in this
repository, not the licenses of these tools.
