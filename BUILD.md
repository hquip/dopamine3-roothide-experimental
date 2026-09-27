# Build the experimental RootHide port

Use the manual workflow **Build experimental Dopamine 3 RootHide port** in
`.github/workflows/roothide-port.yml`. It builds the current repository on
GitHub's macOS runner and uploads an IPA plus logs as an Actions artifact.

See [README.md](README.md) for Windows/GitHub instructions and
[PORTING.md](PORTING.md) for the unverified device and runtime compatibility.
This replaces the old Dopamine 2 TIPA workflow and its screenshots.

No iPhone or prior jailbreak is required for source editing or cloud compilation.
Device signing, installation, jailbreak execution and testing are later steps.
