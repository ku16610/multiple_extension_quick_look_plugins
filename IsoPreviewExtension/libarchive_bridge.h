#ifndef LIBARCHIVE_BRIDGE_H
#define LIBARCHIVE_BRIDGE_H

#include <stdint.h>

char* archive_list_entries(const char* path);
void  archive_free_json(char* json);

#endif
