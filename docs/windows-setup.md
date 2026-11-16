# Windows setup and drivers

Use **Help → Windows Setup & Drivers** in macOpenVM to keep these instructions
beside Windows Setup. The guide also opens from the Windows creation screen and
the selected VM.

You need your own **Windows 11 ARM64 ISO**. macOpenVM does not include Windows.
This is currently a source-only alpha: the public repository does not yet supply
the complete Windows host runtime. These steps apply when the reviewed Windows
runtime and its driver disc are available in your development installation.

## Install the drivers together

With a development app that bundles Guest Tools, shut down Windows and open
**Machine → Install Guest Tools**. Choose your graphics mode in **Graphics
Settings** first, then **Prepare Guest Tools → Start Windows**. The app attaches
the matching disc and starts on the setup display, which works before installing
the graphics driver.

In Windows, choose the Guest Tools AutoPlay action, or open **File Explorer →
This PC → macOpenVM Guest Tools → Install macOpenVM Tools**. Choose **Install**
and approve the administrator prompt. The installer checks the packaged files,
installs the matching drivers together and reports each result. Restart Windows
if requested, then select **Show Windows GPU Display** in the Mac's Guest Tools
window. No command prompt or individual INF selection is needed at the desktop.

The accelerated profile includes the signed Neptune guest package paired with
macOpenVM's modified QEMU/Metal runtime. The basic VirtIO display package is a
different profile; installing it does not enable acceleration. Experimental HDR
driver builds are not included. Source builds can prepare these optional discs
using the [Guest Tools build instructions](guest-tools-build.md).

If graphics is **not detected**, installation is incomplete. Choose **Restart**
from Windows' Start menu and run the installer again. If it remains missing,
check the VM's Graphics Settings. An unattached optional guest-communication
device is reported separately; attaching a tools disc does not create that device.

## Make fullscreen sharp

Shut down Windows, then choose **Machine → Graphics Settings → Match This Mac**
and **Save Settings**. Start Windows and enter fullscreen from **View**. The
preset requests the Mac's fullscreen pixel dimensions at startup. Keep Windows'
own display scaling at a comfortable text size; it is separate from resolution.
Windows can retain its previously saved resolution. If borders remain, compare
**View → Windows Display** with **Mac Viewport**. The startup request alone does
not confirm that Windows applied it; check **Settings → System → Display** inside
Windows for the current resolution.

**Fit to Window** smooths fractional scaling when the window and guest sizes
differ. **Integer Pixels** preserves whole source pixels and can leave borders.
Live resolution changes remain experimental: the current accelerated driver
has restarted Windows during a resize. Prefer requesting the startup size;
automatic live resizing is not enabled.

## Get through “Let’s connect you to a network”

1. **Enable networking.** Stop the VM. In macOpenVM choose **Machine → Networking
   Settings**, select **Shared**, then **Save**. This gives Windows outbound access
   to your local network and the internet. **Disconnected** creates no adapter;
   installing a driver alone will not connect it.
2. **Attach the driver disc.** While stopped, choose **Machine → Install Guest
   Tools → Prepare Guest Tools**. The app selects the matching reviewed disc.
   Choose **Start Windows**.
3. **Install NetKVM.** In Windows choose **Install driver**, browse to the driver
   disc, open **drivers → netkvm**, and select that folder. Keep **Include
   subfolders** selected if shown. Wait for Windows to install the driver and
   establish a connection, then choose **Next**.

The disc's drive letter can vary. Choose the disc containing the `drivers` folder,
not the Windows installation ISO. Shared networking appears as virtual Ethernet;
you do not select a Wi-Fi network inside Windows.

The folder picker may say **“No items match your search”** inside `netkvm` because
it shows folders rather than driver files. If the address bar ends in `netkvm`,
choose **Select Folder**; you do not need to select an individual `.inf` file.

## Driver download

[Download the ARM64 driver ZIP](https://github.com/alexanderisgood/macOpenVM/releases/download/windows-arm64-virtio-0.1.302-1/macOpenVM-virtio-win-0.1.302-1-arm64.zip)
or open the [driver release page, licenses and checksums](https://github.com/alexanderisgood/macOpenVM/releases/tag/windows-arm64-virtio-0.1.302-1).

| Driver | Purpose | When to install |
|---|---|---|
| NetKVM | Network connection | The VM uses Shared networking with its VirtIO network adapter |
| VirtIO serial | Guest communication transport | Your runtime provides the corresponding serial device |
| VirtIO GPU 2D | Basic display support | Your runtime provides the matching VirtIO display device |

The ZIP contains drivers, licenses and checksums. It is **not an ISO** and cannot
be attached through the driver-disc command. Download it on the Mac if Windows
has no connection. The standalone download is separate from the bundled Guest
Tools installer. Source contributors must explicitly build the reviewed discs
before packaging them. Do not rename the ZIP to `.iso`.

## If a step fails

- **The app cannot attach the disc:** keep the VM stopped and check that the
  reviewed driver disc for your runtime is present. A public source build alone
  does not include it. Do not replace a pinned disc with an unrelated download.
- **Windows cannot find a compatible driver:** confirm Shared networking is saved,
  restart the VM, and select `drivers/netkvm` on the driver disc. Use ARM64 drivers.
- **The driver installs but there is no connection:** confirm the Mac itself has
  internet access, then check that the VM restarted after enabling Shared.
- **Windows rejects the driver signature:** keep signature enforcement enabled
  and report the exact error and driver version.

The ordinary firmware display works without the VirtIO GPU driver. Accelerated
graphics uses a separate matched host runtime and Neptune driver; the basic driver
ZIP does not enable acceleration. See the [driver overview](../README.md#windows-11-arm64-guest-drivers).

Guest connectivity, accelerated graphics and broad M-series support remain
experimental. An attached disc is not proof that its drivers are installed.
