# Port.21: passive installation-start observation

The device still returns EIO after port.20. This build only adds observation so
the next error can distinguish pipe/IPC/reply failures from the existing server
handler's failure stage. It is not yet a verified fix for that EIO.

The existing action 8 reply can carry one optional scalar stage. Its scope is
request-local and thread-local; nested requests save and restore their own state.
The original result, routing, permissions and handler behavior remain unchanged.
No new RPC, file logging, retries or process identity operations are added.

The client records only that same thread's request, transport return, reply
validity, original result and optional stage. Its optional copy/clear functions
preserve errno and perform no IPC. Sileo reads them immediately after an existing
failed spawn and clearly marks absent/unsupported observations. Older consumers
can ignore the extra reply field.

Several binaries embed the client sources independently. The pure helper follows
their `jbclient_*.c` source pattern and is explicitly included by the CLI target.
Only systemhook, which owns the existing spawn wrapper, exports the optional
clear/copy observers. Every client publisher binds to its own hidden function
and TLS record, preventing a consumer from reading another module's record.
Two actual shared libraries test both load orders, export lookup, local records,
errno preservation and independent threads before the IPA is built.

Inert tests extract production client/dispatcher code and link the actual pure
observation helper. Results, errno and release counts are compared with port.20,
including transport failures with invalid reply pointers, missing/malformed
replies, nested calls and independent threads. No real identity operation is
linked or executed by these tests. Full macOS/iOS CI and a device retry remain
required; observation itself must not be presented as an installation fix.

Kernel, credential helper, injection and permission-check implementations are
unchanged. The app bundles the reviewed Sileo diagnostic consumer so recovery
does not overwrite it with a version unable to display the observation.
