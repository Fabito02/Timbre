#ifndef LIBTIMBRE_H
#define LIBTIMBRE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct TimbrePlayerHandle TimbrePlayerHandle;

typedef struct CTrack {
    char *id;
    char *title;
    char *artists;
    char *album;
    char *thumbnail_url;
    uint64_t duration_secs;
} CTrack;

typedef struct CTrackList {
    CTrack *items;
    size_t len;
} CTrackList;

TimbrePlayerHandle* timbre_player_new(void);
void timbre_player_free(TimbrePlayerHandle *handle);
bool timbre_player_play_file(TimbrePlayerHandle *handle, const char *path);
bool timbre_player_play_url(TimbrePlayerHandle *handle, const char *url, uint64_t duration_secs);
void timbre_player_pause(TimbrePlayerHandle *handle);
void timbre_player_resume(TimbrePlayerHandle *handle);
void timbre_player_stop(TimbrePlayerHandle *handle);
bool timbre_player_seek(TimbrePlayerHandle *handle, double target_secs);
double timbre_player_get_position(TimbrePlayerHandle *handle);
bool timbre_player_is_finished(TimbrePlayerHandle *handle);
bool timbre_player_play_track_id(TimbrePlayerHandle *handle, const char *track_id, uint64_t duration_secs);

CTrackList* timbre_player_search_tracks(TimbrePlayerHandle *handle, const char *query);
void timbre_track_list_free(CTrackList *list);

#endif