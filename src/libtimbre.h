#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct TimbrePlayerHandle TimbrePlayerHandle;

TimbrePlayerHandle* timbre_player_new(void);
void timbre_player_free(TimbrePlayerHandle* handle);

bool timbre_player_play_file(TimbrePlayerHandle* handle, const char* path);
bool timbre_player_play_url(TimbrePlayerHandle* handle, const char* url, uint64_t duration_secs);

void timbre_player_pause(TimbrePlayerHandle* handle);
void timbre_player_resume(TimbrePlayerHandle* handle);
void timbre_player_stop(TimbrePlayerHandle* handle);

bool timbre_player_seek(TimbrePlayerHandle* handle, double target_secs);
double timbre_player_get_position(TimbrePlayerHandle* handle);
bool timbre_player_is_finished(TimbrePlayerHandle* handle);

bool timbre_player_play_track_id(TimbrePlayerHandle* handle, const char* track_id);
