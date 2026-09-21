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
    bool is_explicit;
    bool available;
    int kind;
    bool set_video_id;
    bool liked;
    uint64_t views;
} CTrack;

typedef struct CTrackList {
    CTrack *items;
    size_t len;
} CTrackList;

typedef struct CAlbum {
    char *id;
    char *title;
    char *artists;
    char *thumbnail_url;
} CAlbum;

typedef struct CAlbumList {
    CAlbum *items;
    size_t len;
} CAlbumList;

typedef struct CPlaylist {
    char *id;
    char *title;
    char *author;
    char *thumbnail_url;
} CPlaylist;

typedef struct CPlaylistList {
    CPlaylist *items;
    size_t len;
} CPlaylistList;

typedef struct CSuggestionList {
    char **items;
    size_t len;
} CSuggestionList;

typedef struct CHomeItem {
    int item_type;
    CTrack *track;
    CAlbum *album;
    CPlaylist *playlist;
} CHomeItem;

typedef struct CHomeSection {
    char *title;
    CHomeItem *items;
    size_t len;
} CHomeSection;

typedef struct CHomeSectionList {
    CHomeSection *sections;
    size_t len;
} CHomeSectionList;

typedef struct CArtist {
    char *id;
    char *name;
    char *thumbnail_url;
} CArtist;

typedef struct CArtistList {
    CArtist *items;
    size_t len;
} CArtistList;

TimbrePlayerHandle* timbre_player_new(void);
void timbre_player_free(TimbrePlayerHandle *handle);
bool timbre_player_play_file(TimbrePlayerHandle *handle, const char *path);
bool timbre_player_play_url(TimbrePlayerHandle *handle, const char *url, uint64_t duration_secs);
bool timbre_player_play_track_id(TimbrePlayerHandle *handle, const char *track_id, uint64_t duration_secs);
void timbre_player_pause(TimbrePlayerHandle *handle);
void timbre_player_resume(TimbrePlayerHandle *handle);
void timbre_player_stop(TimbrePlayerHandle *handle);
bool timbre_player_seek(TimbrePlayerHandle *handle, double target_secs);
double timbre_player_get_position(TimbrePlayerHandle *handle);
bool timbre_player_is_finished(TimbrePlayerHandle *handle);
double timbre_player_get_duration(TimbrePlayerHandle *handle);

CTrackList* timbre_player_search_tracks(TimbrePlayerHandle *handle, const char *query);
CAlbumList* timbre_player_search_albums(TimbrePlayerHandle *handle, const char *query);
CPlaylistList* timbre_player_search_playlists(TimbrePlayerHandle *handle, const char *query);
CSuggestionList* timbre_player_search_suggestions(TimbrePlayerHandle *handle, const char *query);
CArtistList* timbre_player_search_artists(TimbrePlayerHandle *handle, const char *query);

void timbre_track_list_free(CTrackList *list);
void timbre_album_list_free(CAlbumList *list);
void timbre_playlist_list_free(CPlaylistList *list);
void timbre_suggestion_list_free(CSuggestionList *list);
void timbre_artist_list_free(CArtistList *list);

void timbre_string_free(char *s);
char* timbre_player_get_home_json(TimbrePlayerHandle *handle);
char* timbre_player_get_album_json(TimbrePlayerHandle *handle, const char *album_id);
char* timbre_player_get_playlist_json(TimbrePlayerHandle *handle, const char *playlist_id);

#endif
