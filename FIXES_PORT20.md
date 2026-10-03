# Port.20: RPC descriptor bounds

Sileo install preparation and ordinary pipes now complete, but the phone's install
command still returns EIO before an APT installation starts. This release fixes a
separately confirmed RPC descriptor memory-safety defect; it is not yet a verified
resolution of that device EIO.

The systemwide settings and persona-request argument arrays lacked a null
terminator. The CD-hash DATA descriptor also needed a readable terminator after
the existing length slot. The dispatcher now checks its eight-slot limit before
reading another descriptor. Existing request fields, argument types, handler
functions, permission checks and DATA decoding behavior are unchanged.

`scripts/test_jbserver_schema.py` extracts all 37 actual production arrays and the
production dispatcher. Inert XPC and handler fixtures test them under ASan without
running device code or changing an identity. The real port.19 source reproduces
four expected overflows; the corrected source also tests routing/permission
rejection and eight-slot bounds. WSL/Linux tests passed; full macOS/iOS CI remains
required before an IPA can be used.

The app bundles the verified Sileo `2.5.1-13+install-feedback.5`, including its
already reviewed cache, path and ordinary pipe fixes, so Restore does not undo
those fixes. The source-error propagation and more accurate app-registration
diagnostic prepared earlier are included. Kernel, exploit, credential-handling
and injection implementations have not been changed in this release.

Installing this app alone does not replace an already running server. A clean
device restart and user-performed activation of the updated app are needed to
validate the new runtime. The current user has confirmed a recoverable backup.
