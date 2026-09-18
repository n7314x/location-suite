#ifndef LOCATION_SELF_MAINTENANCE_H
#define LOCATION_SELF_MAINTENANCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LSAccountSession LSAccountSession;

typedef struct {
    uint8_t *bytes;
    size_t length;
} LSByteBuffer;

typedef int32_t (*LSTwoFactorCallback)(void *context, char *output, size_t capacity);

int32_t ls_apple_sign_in(
    const char *apple_id,
    const char *password,
    const char *anisette_endpoints_json,
    const char *storage_directory,
    uint32_t timeout_seconds,
    LSTwoFactorCallback callback,
    void *callback_context,
    LSAccountSession **output_session,
    char **output_summary_json,
    char **output_error_json
);

int32_t ls_account_select_team(
    LSAccountSession *session,
    const char *team_identifier,
    char **output_error_json
);

int32_t ls_refresh_profile(
    LSAccountSession *session,
    const char *device_udid,
    const char *device_name,
    const char *portal_bundle_identifier,
    LSByteBuffer *output_profile,
    char **output_error_json
);

void ls_account_session_free(LSAccountSession *session);
void ls_byte_buffer_free(LSByteBuffer buffer);
void ls_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
