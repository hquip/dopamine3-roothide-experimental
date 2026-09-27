#ifndef SIGNATURES_H
#define SIGNATURES_H

#include <choma/CodeDirectory.h>
#include <choma/Fat.h>

typedef enum {
	// Preserve the values used by existing RootHide clients on the wire.
	SIGNATURE_SOURCE_FILE = 0,
	SIGNATURE_SOURCE_PROC = 1,
	SIGNATURE_SOURCE_ALLOCATION = 2,
} signature_source_t;

struct siginfo {
	signature_source_t source;
	fsignatures_t signature;
};

typedef uint8_t cdhash_t[CS_CDHASH_LEN];

bool code_signature_calculate_adhoc_cdhash(CS_SuperBlob *superblob, cdhash_t cdhashOut);
void fat_collect_untrusted_cdhashes(Fat *fat, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut);
void file_collect_untrusted_cdhashes(int fd, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut);
void file_collect_untrusted_cdhashes_by_path(const char *path, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut);
void file_collect_signatures(int fd, struct siginfo **sigInfosOut, uint32_t *sigInfoCountOut);
CS_SuperBlob *siginfo_resolve_superblob(struct siginfo *siginfo, int pid, int fd);
int trust_signatures(int pid, int fd, struct siginfo *sigInfos, uint32_t sigInfoCount);
#endif
