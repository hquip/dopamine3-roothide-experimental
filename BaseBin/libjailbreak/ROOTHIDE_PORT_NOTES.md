# RootHide 2 to Dopamine 3: low-level port status

This is an unbuilt source integration, not evidence of iOS 18.3 device support.
The content base is Dopamine 2.4.9, the target is Dopamine 3.0.10, and the
RootHide input is Dopamine2-roothide tag 27 (2.4.9.27).

The port retains Dopamine 3's kernel offsets, IOSurface cache-mode handling,
SPTM/TXM paths, five-output check-in protocol, trust-file attachment argument,
and all six dyldhook architecture/OS outputs. RootHide's brand fields, path
resolution, signature randomization, and non-inherited IOSurface remapping are
added to those interfaces.

Protocol decisions:

- RootHide keeps domain 5; the Dopamine app domain moves to 6.
- Signature source values remain FILE=0 and PROC=1 for existing RootHide
  clients. Dopamine 3's allocation source is explicitly 2.
- New Mach clients use the distinct `JBSERVER_MACH_MAGIC_V3`; legacy RootHide
  requests retain their original magic and explicit legacy check-in/trust-file
  layouts. The server selects a layout from the request magic, not from the
  check-in request size (which is identical between versions).
- The four changed check-in/trust-file C APIs retain their old exported names
  and parameter counts as wrappers. New code uses the `_v3` symbols for the
  additional output/attachment argument. This prevents an old caller's absent
  fifth argument from being treated as an output pointer.
- Remaining precompiled dependency interfaces still need an ABI audit or
  rebuild, especially direct `gSystemInfo` layout access. Unversioned ordinary
  Dopamine 3 binaries used the old magic with a newer layout and cannot be
  distinguished from RootHide 2 check-in requests; mixing those binaries with
  this port is unsupported. Domain compatibility alone is insufficient.
- Generated dyld is consumed from `/basebin/gen/dyld`.

Before device deployment, the following remain to be verified:

1. RootHide's private vnode/namecache layouts in `roothider/unsandbox.h` and
   `unsandbox1.m` / `unsandbox2.m`, and the additional namecache/sysctl symbols,
   against the actual iOS 18.3 kernel. The fileproc/fileglob accesses use the
   Dopamine 3 offset table, but this does not validate the remaining layouts.
2. The dyld `expandAtLoaderPath` symbol, MachOMerger hook, remote task/thread
   patching, PAC behavior, and exception handling on the target device.
3. A macOS/Xcode build with the intended ChOma/XPF revisions, the dyldhook
   self-contained-symbol checks, signing and packaged dependency resolution.
4. Disk signature randomization, memory-backed signatures, and TXM attachment
   behavior. The public Fat collector preserves in-memory behavior; only the
   file-backed collector randomizes files. Systemwide trust prepares files
   before collecting the signatures consumed by Dopamine 3.
5. RootHide bootstrap/manager/plugin ABI compatibility, process launch,
   userspace reboot, recovery, and selected-app behavior. A successful source
   merge does not demonstrate jailbreak-detection resistance.

No build, device installation, kernel modification, or detection test has been
performed as part of this source integration.
