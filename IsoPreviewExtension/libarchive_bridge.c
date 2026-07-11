#include "libarchive_bridge.h"
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct archive;
struct archive_entry;

struct archive* archive_read_new(void);
int archive_read_support_filter_all(struct archive*);
int archive_read_support_format_iso9660(struct archive*);
int archive_read_open_filename(struct archive*, const char*, size_t);
int archive_read_next_header(struct archive*, struct archive_entry**);
const char* archive_entry_pathname(struct archive_entry*);
int64_t archive_entry_size(struct archive_entry*);
int archive_entry_filetype(struct archive_entry*);
int archive_read_data_skip(struct archive*);
int archive_read_close(struct archive*);
int archive_read_free(struct archive*);

#define AE_IFDIR 0040000

char* archive_list_entries(const char* path) {
    struct archive* a = archive_read_new();
    if (!a) return NULL;

    archive_read_support_filter_all(a);
    archive_read_support_format_iso9660(a);

    if (archive_read_open_filename(a, path, 10240) != 0) {
        archive_read_free(a);
        return NULL;
    }

    size_t buf_size = 4096;
    char* json = (char*)malloc(buf_size);
    if (!json) { archive_read_free(a); return NULL; }

    strcpy(json, "[");
    size_t pos = 1;
    int first = 1;

    struct archive_entry* entry;
    while (archive_read_next_header(a, &entry) == 0) {
        const char* name = archive_entry_pathname(entry);
        int64_t size = archive_entry_size(entry);
        int is_dir = (archive_entry_filetype(entry) == AE_IFDIR);

        if (!name) name = "";

        if (!first) {
            if (pos + 1 >= buf_size) break;
            json[pos++] = ',';
        }
        first = 0;

        size_t name_len = strlen(name);
        size_t needed = pos + 64 + name_len * 2 + 16;
        if (needed > buf_size) {
            buf_size = needed + 4096;
            char* new_json = (char*)realloc(json, buf_size);
            if (!new_json) { free(json); archive_read_free(a); return NULL; }
            json = new_json;
        }

        pos += snprintf(json + pos, buf_size - pos, "{\"name\":\"");
        for (const char* c = name; *c; c++) {
            if (*c == '\\' || *c == '"') { json[pos++] = '\\'; }
            json[pos++] = *c;
        }
        pos += snprintf(json + pos, buf_size - pos,
            "\",\"size\":%lld,\"isDirectory\":%s}",
            (long long)size, is_dir ? "true" : "false");

        archive_read_data_skip(a);
    }

    if (pos < buf_size) {
        json[pos++] = ']';
        json[pos] = '\0';
    }

    archive_read_close(a);
    archive_read_free(a);
    return json;
}

void archive_free_json(char* json) {
    free(json);
}
