#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <fcntl.h>
#include <mach/mach.h>

#include "jbclient_xpc.h"

static void print_usage(FILE *stream)
{
    fprintf(stream,
        "Usage: dopamine <command>\n"
        "  status       Query whether RootHide is reachable for this caller\n"
        "  root-path    Print the active randomized jailbreak root\n"
        "  help         Show this help\n"
        "\n"
        "The upstream Corellium install/activate commands are not supported\n"
        "by this RootHide port. Use the Dopamine app to install or activate.\n");
}

static int require_roothide(void)
{
    // This query uses RootHide's existing permission handler. A refused caller
    // must not be mistaken for proof that the whole device is unjailbroken.
    if (!jbclient_roothide_jailbroken()) {
        fprintf(stderr, "RootHide is unavailable to this caller (inactive or access denied).\n");
        return EX_UNAVAILABLE;
    }
    return EX_OK;
}

int main(int argc, char *argv[])
{
    if (argc == 1 || (argc == 2 &&
        (!strcmp(argv[1], "help") || !strcmp(argv[1], "--help") || !strcmp(argv[1], "-h")))) {
        print_usage(stdout);
        return EX_OK;
    }

    if (!strcmp(argv[1], "install") || !strcmp(argv[1], "activate")) {
        // These used to run a Corellium-specific rootless bootstrap, create a
        // global /var/jb link and mount fakelib. None is a RootHide activation
        // API. Reject the command before running RPCs, parsing a tarball or
        // modifying the system; do not impersonate the app-only Dopamine RPC.
        fprintf(stderr, "The '%s' command is not supported by the RootHide port. Use the Dopamine app.\n", argv[1]);
        return EX_UNAVAILABLE;
    }

    if (argc != 2) {
        print_usage(stderr);
        return EX_USAGE;
    }

    if (!strcmp(argv[1], "status")) {
        int result = require_roothide();
        if (result != EX_OK) return result;
        puts("RootHide is active and reachable for this caller.");
        return EX_OK;
    }

    if (!strcmp(argv[1], "root-path")) {
        int result = require_roothide();
        if (result != EX_OK) return result;
        // The systemwide server supplies the randomized path. Do not infer it
        // from a global link or elevate through Dopamine's app-only domain.
        const char *rootPath = jbclient_get_jbroot();
        if (!rootPath || rootPath[0] != '/') {
            fprintf(stderr, "The RootHide server did not return an active jailbreak root.\n");
            return EX_UNAVAILABLE;
        }
        puts(rootPath);
        // jbclient_get_jbroot returns client-owned static storage.
        return EX_OK;
    }

    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    print_usage(stderr);
    return EX_USAGE;
}
